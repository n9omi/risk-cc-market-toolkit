# =============================================================================
#  config.R  |  Market risk workflow: portfolio and model settings
# =============================================================================
#
#  Change assumptions here, not inside the scripts. Every script sources
#  this file, so one edit flows through the whole workflow.
# -----------------------------------------------------------------------------

source("R/helpers.R")
PATHS <- project_paths("market-risk")


# ---- Portfolio --------------------------------------------------------------
# A $10mm multi-asset book with a commodity tilt, held as constant dollar
# positions (rebalanced daily). Liquid ETFs stand in for each risk factor.
# XLE is SHORT: it hedges the oil position with energy equities, so you can
# see a position that REDUCES portfolio risk in the component-VaR table.

PORTFOLIO <- tibble::tribble(
  ~ticker, ~asset_class, ~description,                        ~position_usd,
  "SPY",   "Equity",     "S&P 500 equities",                        4.0e6,
  "TLT",   "Rates",      "20+ year US Treasuries",                  3.0e6,
  "GLD",   "Commodity",  "Gold",                                    1.0e6,
  "USO",   "Commodity",  "WTI crude oil (front-month futures)",     1.5e6,
  "UNG",   "Commodity",  "Henry Hub natural gas (futures)",         0.5e6,
  "XLE",   "Equity",     "US energy equities (short hedge)",       -1.0e6
)

# Market context series from FRED (not part of the P&L)
FRED_SERIES <- c(VIX = "VIXCLS", UST10Y = "DGS10")


# ---- Dates ------------------------------------------------------------------
# UNG starts trading in April 2007, so June 2007 is the first date where every
# ETF has a price. That still gives a full year of history before the 2008
# crisis, so the backtest covers Lehman.
START_DATE <- "2007-06-01"


# ---- Model settings ---------------------------------------------------------
VAR_CONF     <- 0.99    # VaR confidence level (Basel 2.5 / FRTB backtesting)
ES_CONF      <- 0.975   # Expected Shortfall confidence level (FRTB)
WINDOW       <- 250     # look-back window in trading days (~1 year)
EWMA_LAMBDA  <- 0.94    # RiskMetrics decay factor for daily data
MC_SIMS      <- 20000   # Monte Carlo scenarios
T_DF         <- 5       # degrees of freedom for the fat-tailed (Student-t) MC
HOLD_DAYS    <- 10      # regulatory holding period for capital (10-day VaR)
SEED         <- 42      # makes the Monte Carlo reproducible

# Basel 2.5 capital multipliers (the "3x" in VaR-based capital)
BASEL_MULT   <- 3
