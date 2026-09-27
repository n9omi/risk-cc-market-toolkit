# =============================================================================
#  run_all.R  |  Run both workflows end to end
# =============================================================================
#
#  Open risk-analytics-r.Rproj in RStudio (so the working directory is the
#  repo root), then:   source("run_all.R")
#
#  Each numbered script can also be run on its own, in order. Every script
#  saves its results to data/processed/, so the next one picks up from there.
# -----------------------------------------------------------------------------

run_scripts <- function(folder) {
  scripts <- sort(list.files(folder, pattern = "^[0-9]{2}_.*\\.R$", full.names = TRUE))
  for (s in scripts) {
    cat("\n#############################################################\n")
    cat("#  Running", s, "\n")
    cat("#############################################################\n")
    source(s, echo = FALSE, local = new.env())
  }
}

t0 <- Sys.time()

run_scripts("market-risk")
run_scripts("counterparty-credit-risk")

cat("\nAll done in", round(difftime(Sys.time(), t0, units = "mins"), 1), "minutes.\n")
cat("Reports:\n",
    " market-risk/outputs/market_risk_summary.md\n",
    " counterparty-credit-risk/outputs/ccr_summary.md\n")
