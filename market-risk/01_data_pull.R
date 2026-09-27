# =============================================================================
#  01_data_pull.R  |  Download raw market data
# =============================================================================
#
#  What this does
#    - Downloads daily prices for each ETF in the portfolio (Yahoo Finance)
#    - Downloads VIX and the 10-year Treasury yield (FRED) for market context
#    - Saves each series untouched in data/raw/ (one CSV per series)
#
#  Why keep raw data separate?
#    A risk team must be able to show exactly what data went into a number.
#    Raw files are never edited; all fixes happen in 02_clean.R and are logged.
#
#  Sources (free, no API key needed)
#    Yahoo Finance via quantmod::getSymbols(src = "yahoo")
#    FRED (St. Louis Fed) via quantmod::getSymbols(src = "FRED")
# -----------------------------------------------------------------------------

source("market-risk/config.R")

step("Downloading ETF prices from Yahoo Finance")
etf_raw <- lapply(PORTFOLIO$ticker, fetch_series,
                  src = "yahoo", from = START_DATE, raw_dir = PATHS$raw)
names(etf_raw) <- PORTFOLIO$ticker

step("Downloading market context series from FRED")
fred_raw <- lapply(FRED_SERIES, fetch_series,
                   src = "FRED", from = START_DATE, raw_dir = PATHS$raw)

step("Quick look at what came back")
pull_log <- data.frame(
  series = c(names(etf_raw), FRED_SERIES),
  source = c(rep("Yahoo", length(etf_raw)), rep("FRED", length(fred_raw))),
  first  = as.Date(sapply(c(etf_raw, fred_raw), function(d) min(d$date))),
  last   = as.Date(sapply(c(etf_raw, fred_raw), function(d) max(d$date))),
  rows   = sapply(c(etf_raw, fred_raw), nrow),
  row.names = NULL
)
print(pull_log)

save_table(pull_log, file.path(PATHS$tables, "01_data_pull_log.csv"))
saveRDS(list(etf = etf_raw, fred = fred_raw), file.path(PATHS$processed, "raw_data.rds"))
