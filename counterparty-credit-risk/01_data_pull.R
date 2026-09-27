# =============================================================================
#  01_data_pull.R  |  Download raw market data from FRED
# =============================================================================
#
#  What this does
#    Downloads every series the counterparty model needs and saves each one,
#    untouched, in data/raw/:
#      - US Treasury yields, 1 month to 30 years  -> discount curve, rates model
#      - EURUSD exchange rate and ECB deposit rate  -> FX model
#      - WTI crude oil spot price                   -> commodity model
#      - ICE BofA corporate spreads by rating       -> default probabilities
#
#  Note on the ICE BofA spread series: FRED only carries a limited recent
#  history for these. That is fine here: CVA needs today's spread only.
# -----------------------------------------------------------------------------

source("counterparty-credit-risk/config.R")

all_series <- c(TSY_SERIES, FX = FX_SERIES, EUR = EUR_RATE, WTI = WTI_SERIES, SPREAD_SERIES)

step("Downloading", length(all_series), "series from FRED")
raw <- lapply(all_series, fetch_series, src = "FRED", from = START_DATE, raw_dir = PATHS$raw)
names(raw) <- all_series

pull_log <- data.frame(
  series = all_series,
  role   = c(paste0("Treasury ", names(TSY_SERIES), "y"), "EURUSD", "ECB deposit rate", "WTI spot",
             paste0(names(SPREAD_SERIES), " corporate OAS")),
  first  = as.Date(sapply(raw, function(d) min(d$date))),
  last   = as.Date(sapply(raw, function(d) max(d$date))),
  rows   = sapply(raw, nrow),
  missing_values = sapply(raw, function(d) sum(is.na(d[[2]]))),
  row.names = NULL
)
pull_log$role[1:length(TSY_SERIES)] <- paste0("Treasury ", signif(as.numeric(names(TSY_SERIES)), 2), "y")
print(pull_log)

save_table(pull_log, file.path(PATHS$tables, "01_data_pull_log.csv"))
saveRDS(raw, file.path(PATHS$processed, "raw_data.rds"))
