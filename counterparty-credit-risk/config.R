# =============================================================================
#  config.R  |  Counterparty credit risk workflow: book and model settings
# =============================================================================
#
#  Change assumptions here, not inside the scripts.
# -----------------------------------------------------------------------------

source("R/helpers.R")
PATHS <- project_paths("counterparty-credit-risk")

START_DATE <- "2005-01-01"   # history for calibration and backtesting


# ---- Market data (all from FRED, free, no API key) --------------------------

# US Treasury constant-maturity yields (percent). Names = tenor in years.
TSY_SERIES <- c(`0.0833` = "DGS1MO", `0.25` = "DGS3MO", `0.5` = "DGS6MO", `1` = "DGS1",
                `2` = "DGS2", `3` = "DGS3", `5` = "DGS5", `7` = "DGS7",
                `10` = "DGS10", `20` = "DGS20", `30` = "DGS30")
FX_SERIES   <- "DEXUSEU"      # USD per 1 EUR
EUR_RATE    <- "ECBDFR"       # ECB deposit facility rate (EUR discounting proxy)
WTI_SERIES  <- "DCOILWTICO"   # WTI crude oil spot, Cushing OK ($/bbl)

# ICE BofA US corporate option-adjusted spreads by rating (percent).
# Used as proxy credit spreads when a counterparty has no liquid CDS.
SPREAD_SERIES <- c(AA = "BAMLC0A2CAA", A = "BAMLC0A3CA", BBB = "BAMLC0A4CBBB",
                   BB = "BAMLH0A1HYBB", B = "BAMLH0A2HYB")


# ---- Counterparties and CSA terms -------------------------------------------
# CSA = Credit Support Annex: the collateral agreement under an ISDA master.
#   threshold  exposure allowed before collateral is called
#   mta        minimum transfer amount (small calls are skipped)
#   mpor_days  margin period of risk: days from last good collateral to close-out
# ba_cva_bucket / is_financial feed the regulatory formulas in 05.
# credit_link says how the counterparty's credit moves with oil (for WWR).

COUNTERPARTIES <- tibble::tribble(
  ~cpty,     ~name,                     ~rating, ~ba_cva_bucket,                       ~is_financial, ~csa,  ~threshold, ~mta,   ~mpor_days, ~credit_link,
  "BANK_A",  "Global Bank A",           "A",     "Financials",                         TRUE,          TRUE,  0,          0.5e6,  10,         "none",
  "CORP_B",  "Industrial Corp B",       "BBB",   "Basic materials/energy/industrials", FALSE,         FALSE, NA,         NA,     NA,         "none",
  "AIR_C",   "Airline C",               "BB",    "Consumer goods/transport",           FALSE,         FALSE, NA,         NA,     NA,         "worse_when_oil_rises",
  "FUND_D",  "Energy Hedge Fund D",     "BB",    "Financials",                         TRUE,          TRUE,  5e6,        0.25e6, 10,         "worse_when_oil_falls"
)


# ---- Trade book -------------------------------------------------------------
# direction = +1 when the BANK is long the main risk factor:
#   IRS   +1 = bank pays fixed / receives floating (gains when rates rise)
#   FXFWD +1 = bank buys EUR forward (gains when EUR rises)
#   WTI   +1 = bank receives floating oil / pays fixed (gains when oil rises)
# notional: USD for swaps, EUR for FX forwards, barrels per month for WTI.
# strike_offset: trades are "seasoned" (done in the past), so strikes sit
#   away from today's market and trades start with non-zero value.
#     IRS: fixed rate = today's par rate + offset
#     FX / WTI: strike = today's forward x (1 + offset)

TRADES <- tibble::tribble(
  ~trade_id, ~cpty,    ~type,   ~direction, ~notional, ~maturity, ~strike_offset, ~description,
  "T1",      "BANK_A", "IRS",    1,          50e6,      5,         -0.0025,        "5y payer swap (bank pays fixed)",
  "T2",      "BANK_A", "IRS",   -1,          30e6,      10,         0.0010,        "10y receiver swap (bank receives fixed)",
  "T3",      "BANK_A", "FXFWD",  1,          20e6,      1,          0.0100,        "1y EUR forward, bank buys EUR",
  "T4",      "CORP_B", "IRS",   -1,          40e6,      7,          0.0040,        "7y swap: corporate hedges floating debt",
  "T5",      "CORP_B", "FXFWD", -1,          15e6,      2,         -0.0100,        "2y EUR forward: importer buys EUR from bank",
  "T6",      "AIR_C",  "WTI",   -1,          25e3,      2,          0.0500,        "2y jet-fuel proxy hedge: airline pays fixed",
  "T7",      "FUND_D", "WTI",   -1,          40e3,      1.5,       -0.0300,        "18m swap: fund is long oil, bank short"
)


# ---- Model settings ---------------------------------------------------------
N_PATHS       <- 5000     # Monte Carlo paths
DT            <- 1 / 12   # monthly simulation grid
HW_A          <- 0.05     # Hull-White mean reversion (normally calibrated to swaptions)
VOL_YEARS     <- 3        # look-back for volatilities and correlations
WTI_CAL_YEARS <- 10       # look-back for the oil mean-reversion model
PFE_Q         <- 0.95     # PFE percentile (credit limits are usually set on PFE)
LGD_MKT       <- 0.60     # market-standard LGD for CVA (40% recovery)
ALPHA         <- 1.4      # Basel alpha multiplier on EAD
WWR_B         <- 0.75     # strength of the oil-credit link in the WWR test
SEED          <- 2026

# Long-run average 1-year default rates by rating (approx. S&P global
# corporate default studies). Used for regulatory PD in the IRB formula.
PD_BY_RATING <- c(AA = 0.0002, A = 0.0005, BBB = 0.0015, BB = 0.0060, B = 0.0300)
