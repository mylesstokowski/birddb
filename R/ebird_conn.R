#' Set up a `DBI`-style database connection to the imported eBird data
#' 
#' Parquet files can be accessed as though they were relational database tables 
#' by setting up a view to the file using DuckDB. This function sets up a view 
#' on either the checklist or observation dataset and returns a [DBI]-style 
#' database connection to the data. The returned object can then be queried 
#' with SQL syntax via [DBI] or with [dplyr] syntax via [dbplyr]. For the latter 
#' approach, consider using the [checklists()] and [observations()] functions 
#' which will return [tbl] objects ready for access using [dplyr] syntax.
#' 
#' @param dataset the type of dataset to set up a connection to, either the 
#' observations of checklists.
#' @param cache_connection should we preserve a cache of the connection? allows
#'   faster load times and prevents connection from being garbage-collected.
#' @param memory_limit the memory limit for DuckDB.
#' 
#' @return A [DBI] connection object using to communicate with the DuckDB 
#'   database containing the eBird data.
#' @export
#' @examples
#' # only use a tempdir for this example, don't copy this for real data
#' temp_dir <- file.path(tempdir(), "birddb")
#' Sys.setenv("BIRDDB_HOME" = temp_dir)
#' 
#' # get the path to a sample dataset provided with the package
#' tar <- sample_observation_data()
#' # import the sample dataset to parquet
#' import_ebird(tar)
#' # set up the database connection
#' con <- ebird_conn(dataset = "observations")
#' 
#' unlink(temp_dir, recursive = TRUE)
#' todo: need a more generic way to connect to subset observations datasets 
ebird_conn <- function(dataset = possible_datasets(),
                       cache_connection = TRUE,
                       memory_limit = 16) {
  
  # todo: check default behavior of match.arg before my modifications
  dataset <- match.arg(dataset)

  conn <- duckdb_connection(memory_limit = memory_limit,
                            cache_connection = cache_connection)
  
  # create the view if does not exist
  
  parquet <- ebird_parquet_files(dataset = dataset)
  # if partitioning by species name, there could be apostrophes in directory
  # names, so we escape single quotes (') as ('')
  parquet <- gsub("'", "''", parquet)
  parquet <- paste(parquet, collapse = "', '")
  
  if (!dataset %in% DBI::dbListTables(conn)){
    # query to create view in duckdb to the parquet file
    view_query <- paste0("CREATE VIEW '", dataset, 
                         "' AS SELECT * FROM parquet_scan(['",
                         parquet, "']);")
    DBI::dbSendQuery(conn, view_query)
  }

  
  conn
}

duckdb_connection <- function(dir = ebird_db_dir(),
                              memory_limit = 16,
                              mc.cores = arrow::cpu_count(),
                              cache_connection = TRUE
                              ) {
  stopifnot(is.logical(cache_connection), 
            length(cache_connection) == 1)
  stopifnot(is.numeric(memory_limit), 
            length(memory_limit) == 1,
            !is.na(memory_limit), 
            memory_limit > 0)
  
  # check for a cached connection
  conn <- mget("birddb", envir = birddb_cache, ifnotfound = NA)[["birddb"]]
  
  # Disconnect if it's an invalid connection (expired in cache)
  if ( db_is_invalid(conn) ) {
    conn <- DBI::dbDisconnect(conn, shutdown = TRUE)
  }
  
  # We don't have a valid cached connection, so we must create one! 
  if (!inherits(conn, "DBIConnection")){
    conn <- DBI::dbConnect(drv = duckdb::duckdb(), dir)  
  }
  
  ## PRAGMAS
  duckdb_mem_limit(conn, memory_limit, "GB")
  duckdb_parallel(conn, mc.cores)
  duckdb_set_tempdir(conn, tempdir())

  # (re)-cache the connection
  if (cache_connection) {
    assign("birddb", conn, envir = birddb_cache)
  }

conn
}

## 
db_is_invalid <- function(conn) {
  inherits(conn, "DBIConnection") && !DBI::dbIsValid(conn)
}

ebird_parquet_files <- function(dataset = possible_datasets()) {
  
  dataset <- match.arg(dataset)
  
  # list of all parquet files
  dir <- file.path(ebird_data_dir(), dataset)
  file <- list.files(dir, pattern = "[.]parquet", 
                     full.names = TRUE, recursive = TRUE)
  
  # currently we're assuming no partitioning is being used hence 1 file
  # will need to modify later if partitioning is implemented
  if (length(file) == 0) {
    stop("No parquet files found in: ", dir)
    # todo: more informative error message that recommends using import_ebird() 
    # with a dataset of type `dataset`?
  }
  
  return(file)
}

# return a character vector of the datasets that have been imported
possible_datasets <- function() {
  existing <- list.dirs(ebird_data_dir(), recursive = FALSE, full.names = FALSE)
  unique(c("observations", "checklists", existing))
}


# environment to store the cached copy of the connection
birddb_cache <- new.env()

# finalizer to close the connection on exit.
# todo: does this just close an observations dataset by default? would we want
# it to also close checklists and any other subset datasets?
local_db_disconnect <- function(db = ebird_conn()){
  if (inherits(db, "DBIConnection")) {
    suppressWarnings({
      DBI::dbDisconnect(db, shutdown = TRUE)
    })
  }
  if (exists("birddb", envir = birddb_cache)) {
    suppressWarnings({
      rm("birddb", envir = birddb_cache)
    })
  }
}
reg.finalizer(birddb_cache, local_db_disconnect, onexit = TRUE)