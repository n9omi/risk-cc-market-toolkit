# =============================================================================
#  helpers.R  |  Shared utilities used by both workflows
# =============================================================================
#
#  Contents
#    1. Packages
#    2. Folder paths
#    3. Data download with a local cache
#    4. Chart theme and colours
#    5. Small formatting / saving helpers
# -----------------------------------------------------------------------------


# ---- 1. Packages ------------------------------------------------------------

suppressPackageStartupMessages({
  library(quantmod)
  library(xts)
  library(zoo)
  library(dplyr)
  library(tidyr)
  library(readr)
  library(ggplot2)
  library(scales)
  library(patchwork)
  library(knitr)
})

options(dplyr.summarise.inform = FALSE, scipen = 999)

if (!file.exists("R/helpers.R")) {
  stop("Run scripts from the repo root (open risk-analytics-r.Rproj in RStudio).")
}


# ---- 2. Folder paths --------------------------------------------------------
# Each workflow keeps its own data/ and outputs/ folders. This creates them
# if they don't exist yet and returns their paths as a list.

project_paths <- function(workflow) {
  base <- file.path(getwd(), workflow)
  paths <- list(
    raw       = file.path(base, "data", "raw"),        # untouched downloads
    processed = file.path(base, "data", "processed"),  # cleaned data, model results
    outputs   = file.path(base, "outputs"),            # summary report
    tables    = file.path(base, "outputs", "tables"),  # CSV tables
    figures   = file.path(base, "outputs", "figures")  # PNG charts
  )
  invisible(lapply(paths, dir.create, recursive = TRUE, showWarnings = FALSE))
  paths
}


# ---- 3. Data download with a local cache ------------------------------------
# Downloads one series from Yahoo Finance or FRED and saves it as a CSV in
# data/raw/. If a fresh copy (less than `max_age_days` old) is already there,
# the download is skipped. If the download fails, the cached copy is used.
#
#   Yahoo symbols: "SPY", "TLT", ...   ->  columns SPY.Open ... SPY.Adjusted
#   FRED symbols:  "DGS10", "VIXCLS"   ->  one column named after the series

# FRED downloads use the `curl` package (the same one quantmod uses for
# Yahoo), which respects your system's certificate settings. That matters
# on work or university networks that inspect secure traffic.
#
#   With an API key:  the official FRED API (JSON). The key is read from
#                     the FRED_API_KEY environment variable, never from code.
#   Without a key:    FRED's public CSV download (no key needed).
#
# To set the key once, run  file.edit("~/.Renviron")  and add the line
#   FRED_API_KEY=your_key_here
# then restart R. ~/.Renviron lives outside this repo, so it never gets
# pushed to GitHub.

fetch_fred <- function(series_id) {
  key <- Sys.getenv("FRED_API_KEY")
  if (nzchar(key)) fetch_fred_api(series_id, key) else fetch_fred_csv(series_id)
}

fetch_fred_api <- function(series_id, key) {
  url <- paste0("https://api.stlouisfed.org/fred/series/observations?series_id=", series_id,
                "&api_key=", key, "&file_type=json")
  res <- curl::curl_fetch_memory(url)
  if (res$status_code != 200) stop("FRED API returned HTTP ", res$status_code,
                                   " (check that FRED_API_KEY is valid)")
  obs <- jsonlite::fromJSON(rawToChar(res$content))$observations
  if (is.null(obs) || nrow(obs) == 0) stop("FRED API returned no observations")
  vals <- suppressWarnings(as.numeric(obs$value))            # FRED marks missing as "."
  xts(matrix(vals, dimnames = list(NULL, series_id)), order.by = as.Date(obs$date))
}

# Handles both CSV layouts: first column "observation_date" or "DATE";
# missing values as "." or blank.
fetch_fred_csv <- function(series_id) {
  url <- paste0("https://fred.stlouisfed.org/graph/fredgraph.csv?id=", series_id)
  tmp <- tempfile(fileext = ".csv")
  on.exit(unlink(tmp))
  curl::curl_download(url, tmp, quiet = TRUE)
  raw <- utils::read.csv(tmp, stringsAsFactors = FALSE, na.strings = c(".", ""))
  if (ncol(raw) < 2 || nrow(raw) == 0) stop("unexpected FRED file format")
  vals <- suppressWarnings(as.numeric(raw[[2]]))
  xts(matrix(vals, dimnames = list(NULL, series_id)), order.by = as.Date(raw[[1]]))
}

fetch_series <- function(symbol, src = c("yahoo", "FRED"), from, raw_dir,
                         max_age_days = 1) {
  src <- match.arg(src)
  cache_file <- file.path(raw_dir, paste0(gsub("[^A-Za-z0-9]", "_", symbol), ".csv"))

  cache_is_fresh <- file.exists(cache_file) &&
    difftime(Sys.time(), file.mtime(cache_file), units = "days") < max_age_days

  if (!cache_is_fresh) {
    x <- tryCatch(
      if (src == "FRED") fetch_fred(symbol)
      else getSymbols(symbol, src = src, from = from, auto.assign = FALSE, warnings = FALSE),
      error = function(e) {
        message("  ! download failed for ", symbol, ": ", conditionMessage(e))
        NULL
      }
    )
    if (!is.null(x)) {
      out <- data.frame(date = index(x), coredata(x), check.names = FALSE)
      write_csv(out, cache_file)
      message("  downloaded ", symbol, " (", nrow(out), " rows)")
    } else if (file.exists(cache_file)) {
      message("  using cached copy of ", symbol)
    }
  } else {
    message("  cached ", symbol, " is fresh, skipping download")
  }

  if (!file.exists(cache_file)) {
    stop("No data for ", symbol, ": download failed and there is no cached copy.")
  }

  # First column is always the date. This also lets you drop in a CSV
  # downloaded by hand from fred.stlouisfed.org ("observation_date" header).
  df <- read_csv(cache_file, show_col_types = FALSE, na = c("", "NA", "."))
  names(df)[1] <- "date"
  df$date <- as.Date(df$date)
  df[df$date >= as.Date(from), ]
}


# ---- 4. Chart theme and colours ---------------------------------------------
# One consistent look for every figure. Colours come from a colour-blind
# checked categorical palette, always assigned in the same order.

PALETTE <- c(
  blue = "#2a78d6", orange = "#eb6834", aqua = "#1baf7a", yellow = "#eda100",
  magenta = "#e87ba4", green = "#008300", violet = "#4a3aa7", red = "#e34948"
)
COL_GAIN <- "#2a78d6"   # diverging pole: gains / good
COL_LOSS <- "#e34948"   # diverging pole: losses / breaches
COL_MID  <- "#f0efec"   # neutral midpoint
COL_INK  <- "#52514e"   # secondary text / reference lines

theme_risk <- function(base_size = 11) {
  theme_minimal(base_size = base_size) +
    theme(
      plot.title       = element_text(face = "bold", colour = "#0b0b0b"),
      plot.subtitle    = element_text(colour = COL_INK),
      plot.caption     = element_text(colour = "grey50", size = 8, hjust = 0),
      axis.text        = element_text(colour = COL_INK),
      panel.grid.minor = element_blank(),
      panel.grid.major = element_line(colour = "grey92", linewidth = 0.3),
      legend.position  = "bottom",
      legend.title     = element_blank(),
      strip.text       = element_text(face = "bold", hjust = 0),
      plot.background  = element_rect(fill = "white", colour = NA)
    )
}


# ---- 5. Small formatting / saving helpers -----------------------------------

# Print a step header in the console so the run log is easy to follow
step <- function(...) cat("\n==>", ..., "\n")

# $ formatting: 1234567 -> "$1.23mm", 12345 -> "$12.3k"
fmt_usd <- function(x, digits = 2) {
  ifelse(abs(x) >= 1e6,
         paste0(ifelse(x < 0, "-", ""), "$", formatC(abs(x) / 1e6, format = "f", digits = digits), "mm"),
         paste0(ifelse(x < 0, "-", ""), "$", formatC(abs(x) / 1e3, format = "f", digits = 1), "k"))
}
fmt_pct <- function(x, digits = 2) paste0(formatC(100 * x, format = "f", digits = digits), "%")

save_plot <- function(p, path, width = 9, height = 5) {
  ggsave(path, p, width = width, height = height, dpi = 150, bg = "white")
  message("  saved ", basename(path))
}

save_table <- function(df, path) {
  write_csv(df, path)
  message("  saved ", basename(path))
}

# Data frame -> markdown table text (for the auto-generated reports)
md_table <- function(df, digits = 2) {
  paste(knitr::kable(df, format = "pipe", digits = digits), collapse = "\n")
}
