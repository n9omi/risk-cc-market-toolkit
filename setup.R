# =============================================================================
#  setup.R  |  One-time setup: install the R packages this repo uses
# =============================================================================
#
#  Run once:   source("setup.R")
#
#  Everything else in the repo is written in base R plus a few common
#  packages. There are no black-box risk packages on purpose: every VaR,
#  backtest, exposure and CVA number is computed by code you can read.
# -----------------------------------------------------------------------------

packages <- c(
  "quantmod",   # downloads prices from Yahoo Finance
  "curl",       # downloads FRED series (handles work/university network certificates)
  "jsonlite",   # reads FRED API responses
  "xts",        # time-series objects (used by quantmod)
  "zoo",        # rolling windows and filling gaps
  "dplyr",      # data wrangling
  "tidyr",      # reshaping wide <-> long
  "readr",      # fast CSV read / write
  "ggplot2",    # charts
  "scales",     # axis formatting ($, %, etc.)
  "patchwork",  # combine several ggplots into one figure
  "knitr"       # turns data frames into markdown tables for the reports
)

missing <- packages[!packages %in% rownames(installed.packages())]

if (length(missing) > 0) {
  message("Installing: ", paste(missing, collapse = ", "))
  install.packages(missing, repos = "https://cloud.r-project.org")
} else {
  message("All packages already installed.")
}

# Quick check that everything loads
invisible(lapply(packages, library, character.only = TRUE))
if (nzchar(Sys.getenv("FRED_API_KEY"))) {
  message("FRED API key found: FRED data will come from the official API.")
} else {
  message("No FRED API key set: using FRED's public CSV download (works without a key).\n",
          "  Optional: run file.edit(\"~/.Renviron\"), add FRED_API_KEY=your_key, restart R.")
}
message("Setup complete. Next: source(\"run_all.R\")")
