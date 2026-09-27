# Counterparty Credit Risk: Exposure Simulation, CVA and SA-CCR

> **The question:** if a derivatives counterparty defaults, how much could we lose? What should we charge for that risk, and how much capital does it need?

A counterparty credit risk (CCR) engine in R:
- Calibrate rates, FX and oil models to real data.
- Simulate how a derivatives book could evolve.
- Measure exposure after netting and collateral.
- Price default risk (CVA), including wrong-way risk.
- Compute regulatory exposure and capital.
- Backtest and validate the models.

---

## Table of contents

- [Overview](#overview)
- [How to use and run](#how-to-use-and-run)
- [Data](#data)
- [Workflow steps in plain language](#workflow-steps-in-plain-language)
- [Outputs](#outputs)
- [Key definitions and concepts](#key-definitions-and-concepts)
- [Models](#models)
- [Regulatory context](#regulatory-context)
- [How to explain this project](#how-to-explain-this-project)
- [Limitations](#limitations)
- [References](#references)

---

## Overview

**Why derivatives are different from loans:** a loan's exposure is roughly its balance. A derivative's exposure is **random**, because what the counterparty owes you depends on where markets go. So exposure has to be simulated.

**The book:** seven trades with four counterparties (edit in `config.R`).

| Counterparty | Rating | Collateral agreement (CSA) | Trades |
|---|---|---|---|
| Global Bank A | A | Yes: zero threshold, $0.5mm MTA, 10-day MPOR | 5y payer swap, 10y receiver swap, 1y EUR forward |
| Industrial Corp B | BBB | No | 7y swap (the corporate hedges floating debt), 2y EUR forward |
| Airline C | BB | No | 2y WTI swap (the airline hedges fuel by paying fixed) |
| Energy Hedge Fund D | BB | Yes: $5mm threshold | 18m WTI swap (the fund is long oil) |

Against both Airline C and Fund D, the bank is **short oil**. Their credit, however, reacts to oil in opposite ways, which gives a clean demonstration of **right-way versus wrong-way risk**.

| Setting | Value | Where to change it |
|---|---|---|
| Monte Carlo paths | 5,000 | `config.R` → `N_PATHS` |
| Time grid | Monthly, out to the longest trade (10y) | `DT` |
| PFE percentile | 95% | `PFE_Q` |
| LGD for CVA | 60% (market standard) | `LGD_MKT` |
| Hull-White mean reversion | 0.05 | `HW_A` |
| Calibration look-back | 3y (volatilities and correlations), 10y (oil mean reversion) | `VOL_YEARS`, `WTI_CAL_YEARS` |
| Wrong-way risk link strength | 0.75 | `WWR_B` |

---

## How to use and run

**Prerequisites**
- R 4.1 or newer
- RStudio (recommended)
- An internet connection on the first run

**Run it**

```r
# 1. Open risk-analytics-r.Rproj in RStudio (sets the working directory to the repo root)
# 2. Install packages (once)
source("setup.R")

# 3a. Run this workflow step by step
source("counterparty-credit-risk/01_data_pull.R")
source("counterparty-credit-risk/02_clean_and_calibrate.R")
source("counterparty-credit-risk/03_trades_and_pricing.R")
source("counterparty-credit-risk/04_exposure_simulation.R")
source("counterparty-credit-risk/05_cva_and_capital.R")
source("counterparty-credit-risk/06_backtest_and_validate.R")
source("counterparty-credit-risk/07_report.R")

# 3b. ...or run both workflows end to end
source("run_all.R")

# 4. Optional: save the report as a styled PDF (uses Chrome or Edge)
source("make_pdfs.R")
```

**Tips**
- **Runtime:** under a minute after the data is downloaded.
- **Scripts hand off through files.** Each script saves its results to `data/processed/*.rds`, so you can re-run any step on its own.
- **Change the book only in `config.R`:** counterparties, CSA terms, trades and model settings.
- **Adding a trade:** add a row to `TRADES`. Supported types are `IRS`, `FXFWD` and `WTI`.
- **Force a fresh download:** delete `counterparty-credit-risk/data/raw/`.
- **If a download fails,** the script uses the cached copy.
- **Optional FRED API key:** FRED data downloads without a key. To use your key, run `file.edit("~/.Renviron")`, add the line `FRED_API_KEY=your_key`, save, and restart R. The key stays on your computer and is never committed to GitHub.
- **"SSL certificate problem" error:** your network (often work, university or VPN) is intercepting secure traffic. Switch to home Wi-Fi or a phone hotspot and rerun. You can also download a series by hand from fred.stlouisfed.org (Download → CSV) and save it in `data/raw/` as `SERIESID.csv`; the scripts read it as-is.
- **PDF without Chrome/Edge:** `make_pdfs.R` still writes an `.html` report. Open it in any browser → Print → Save as PDF.
- **Publishing to GitHub:** commit `outputs/` so the report renders. `data/` is git-ignored.

---

## Data

All data comes from [FRED](https://fred.stlouisfed.org/) (Federal Reserve Bank of St. Louis). It is free and no API key is required. If `FRED_API_KEY` is set, series come from the official FRED API; otherwise from FRED's public CSV download. Both return the same data.

| Series (FRED ID) | What it is | Used for | Quirks handled |
|---|---|---|---|
| `DGS1MO` … `DGS30` (11 tenors) | US Treasury constant-maturity yields, 1 month to 30 years (%) | Today's discount curve; Hull-White volatility; rates backtest | Holidays blank → dropped; short gaps carried forward |
| `DEXUSEU` | USD per 1 EUR (noon buying rate) | FX spot, volatility and backtest | Published weekly, so it can trail the Treasury data by a few days |
| `ECBDFR` | ECB deposit facility rate (%) | EUR discount rate for FX forwards | A step series; carried forward |
| `DCOILWTICO` | WTI crude spot, Cushing OK ($/bbl) | Oil spot, Schwartz calibration and backtest | **Negative print on 20 Apr 2020** → flagged and interpolated (a log-price model cannot take negatives) |
| `BAMLC0A2CAA`, `BAMLC0A3CA`, `BAMLC0A4CBBB`, `BAMLH0A1HYBB`, `BAMLH0A2HYB` | ICE BofA US corporate option-adjusted spreads (OAS), AA / A / BBB / BB / B (%) | Proxy credit spreads → default intensities for CVA | FRED carries limited history for ICE series; only the latest value is needed |

**Valuation date:** the latest date on which the Treasury curve, EURUSD and WTI all have data.

**Default probabilities for capital:** long-run average 1-year default rates by rating (approximately S&P global corporate default studies), set in `config.R`.

---

## Workflow steps in plain language

### Step 1: Get the data (`01_data_pull.R`)
1. Download the 19 FRED series listed above.
2. Save each one untouched in `data/raw/` and print a log of dates, row counts and missing values.

### Step 2: Clean the data and fit the models (`02_clean_and_calibrate.R`)
1. **Clean:** drop holidays, fill short gaps, fix WTI's negative print, and check for stale values. Every fix is logged.
2. **Pick the valuation date:** the latest day with complete data.
3. **Build today's yield curve:** convert Treasury yields to zero rates and discount factors.
4. **Calibrate the risk-factor models on history:**
   - **Rates:** how volatile are daily changes in the 1-year yield?
   - **FX:** how volatile is EURUSD?
   - **Oil:** how fast does the price pull back to its long-run level, what is that level, and how volatile is it?
5. **Measure correlations** between daily rate, FX and oil moves.
6. **Turn credit spreads into default intensities** with the credit triangle (hazard = spread ÷ LGD).

### Step 3: Build and price the trade book (`03_trades_and_pricing.R`)
1. Set each trade's strike from today's market: the par swap rate or forward price, plus an offset so trades look like they were done in the past.
2. Price every trade today (mark-to-market).
3. **Check the pricers:** a trade struck exactly at market must be worth zero. The script stops if it isn't.
4. Compute sensitivities by bumping the market and repricing: DV01 (+1bp), FX delta (+1%), oil delta (+$1).
5. Prepare the trade fields the regulatory formulas need.

### Step 4: Simulate future exposure (`04_exposure_simulation.R`)
1. **Simulate** 5,000 correlated paths of interest rates, EURUSD and oil, month by month out to 10 years.
2. **Reprice** every trade on every path at every month.
3. **Net** trades by counterparty. Under an ISDA agreement, only the net amount is at risk.
4. **Apply collateral** for counterparties with a CSA. Collateral reflects the value 10 days earlier, because the counterparty stops posting before it defaults.
5. **Measure exposure:** expected exposure (EE), 95% potential future exposure (PFE), and EEPE, which gives the IMM-style EAD.
6. **Stress today's exposure:** instant shocks to rates, FX and oil, then reprice.
7. Chart the exposure profiles and the simulated risk factors.

### Step 5: Price the credit risk and compute capital (`05_cva_and_capital.R`)
1. **CVA:** add up discounted expected exposure × probability of default in each period × LGD.
2. **CS01:** measure how much CVA changes if credit spreads widen by 1bp.
3. **Wrong-way risk:** tie each energy-linked counterparty's default risk to the oil price on each path, then re-compute CVA and compare.
4. **SA-CCR:** compute the standardised regulatory exposure, EAD = 1.4 × (replacement cost + add-on).
5. **Capital:**
   - **IRB:** default-risk capital from the Vasicek formula.
   - **BA-CVA:** capital for the risk that CVA itself moves.

### Step 6: Backtest and validate (`06_backtest_and_validate.R`)
1. **Backtest the forecasts.** At each past month-end, calibrate using only data up to that date, then forecast rates, FX and oil 1 month and 3 months ahead. See where reality landed in each forecast.
   - **Coverage test:** roughly 5% of outcomes should fall outside the 95% band.
   - **KS test:** the "where it landed" values should be spread evenly.
2. **Martingale tests:** simulated discounted prices must average back to today's prices. If they don't, the simulation has a bug.
3. **Monte Carlo convergence:** check that 5,000 paths give CVA within a few percent.

### Step 7: Write the report (`07_report.R`)
1. Collect everything into `outputs/ccr_summary.md`.
2. Generate the written observations from the results.

---

## Outputs

| File | What it shows |
|---|---|
| `outputs/ccr_summary.md` | **Start here.** Full report with tables, charts, observations and regulatory notes |
| `outputs/ccr_summary.pdf` / `.html` | Styled PDF and web versions of the report (after `make_pdfs.R`) |
| `tables/02_model_parameters.csv`, `02_factor_correlations.csv` | Calibrated model inputs |
| `tables/02_curve_today.csv`, `02_credit_spreads_hazards.csv` | Discount curve; spreads and default intensities |
| `tables/03_trade_book.csv`, `03_pricing_checks.csv` | Trades, MTM, sensitivities, pricing checks |
| `tables/04_exposure_profiles.csv`, `04_exposure_summary.csv` | EE and PFE over time; peak PFE, EEPE, IMM EAD |
| `tables/04_stressed_current_exposure.csv` | MTM under instant shocks |
| `tables/05_cva.csv`, `05_wrong_way_risk.csv` | CVA, CS01, wrong-way risk effect |
| `tables/05_saccr.csv`, `05_capital_by_counterparty.csv`, `05_capital_totals.csv` | SA-CCR components, EAD, RWA |
| `tables/06_pit_backtest_results.csv`, `06_martingale_tests.csv`, `06_mc_convergence.csv` | Validation results |
| `figures/*.png` | All charts, numbered by the script that made them |

---

## Key definitions and concepts

**Exposure**

| Term | Plain-language definition |
|---|---|
| **Mark-to-market (MTM)** | What a trade is worth today. Positive means the counterparty owes the bank. |
| **Exposure** | max(value − collateral, 0). Only positive value is lost in a default. |
| **Netting / netting set** | Under an ISDA master agreement, all trades with one counterparty offset each other. The netting set is the group of trades that net. |
| **CSA (Credit Support Annex)** | The collateral agreement under an ISDA master: who posts, when, and how much. |
| **Variation margin (VM)** | Collateral posted to cover current MTM. |
| **Threshold** | Exposure allowed before any collateral is called. |
| **MTA (minimum transfer amount)** | The smallest collateral call that will actually be made. |
| **MPOR (margin period of risk)** | Time from the last good collateral posting to closing out the defaulted trades, 10+ business days. The main reason collateral doesn't remove all exposure. |
| **EE (expected exposure)** | The average exposure at a future date, across all paths. |
| **PFE (potential future exposure)** | A high percentile (here 95%) of exposure at a future date. **Credit limits are set on PFE.** |
| **EPE** | The average of EE over a time period. |
| **Effective EE / EEPE** | EE forced never to decrease (running maximum), averaged over the first year. Basel's IMM measure: **EAD = α × EEPE**, with α = 1.4. |
| **EAD (exposure at default)** | The regulatory exposure amount that capital is calculated on. |

**Credit and CVA**

| Term | Plain-language definition |
|---|---|
| **CVA (credit valuation adjustment)** | The market price of counterparty default risk: CVA = LGD × Σ discounted EE × probability of default in each period. It reduces the fair value of the derivatives. |
| **DVA** | The mirror image of CVA for the bank's own default risk. |
| **xVA** | The family of valuation adjustments: CVA, DVA, FVA (funding), MVA (initial margin), KVA (capital). |
| **LGD (loss given default)** | The fraction lost if the counterparty defaults (1 − recovery rate). |
| **Hazard rate (λ)** | The instantaneous default intensity. Survival to time t = e^(−λt). |
| **Credit triangle** | Spread ≈ λ × LGD, so λ = spread ÷ LGD. |
| **CS01** | Change in CVA for a 1bp widening in the counterparty's credit spread. It is how CVA desks size hedges. |
| **Wrong-way risk (WWR)** | Exposure is highest exactly when the counterparty is most likely to default. **Right-way risk** is the reverse. |

**Validation**

| Term | Plain-language definition |
|---|---|
| **Risk-neutral vs real-world** | Pricing (CVA) uses risk-neutral dynamics consistent with market prices. Risk limits (PFE) often use historically estimated real-world dynamics. |
| **Martingale test** | Checks that discounted simulated prices average back to today's market prices. A standard simulation validation check. |
| **PIT (probability integral transform)** | Takes each realised value's position within its forecast distribution. If the model is right, these values are uniform on [0, 1]. |

**Regulatory capital**

| Term | Plain-language definition |
|---|---|
| **SA-CCR** | Basel's standardised derivative exposure: EAD = 1.4 × (RC + multiplier × AddOn). The add-on uses supervisory factors: 0.5% for rates, 4% for FX, 18% for oil and gas. |
| **RC (replacement cost)** | The cost to replace the trades today, net of collateral. |
| **RWA (risk-weighted assets)** | Capital requirement × 12.5. Banks must hold capital of at least 8% of RWA. |
| **IRB / Vasicek formula** | Capital at the 99.9th percentile of a one-factor default model, driven by probability of default (PD), LGD, maturity and asset correlation. |

---

## Models

| Risk factor | Model | Why this model | Calibration |
|---|---|---|---|
| USD rates | **Hull-White one-factor** short rate: dr = [θ(t) − a·r]dt + σ·dW | Fits today's curve exactly; bond prices have a closed form, so swaps reprice instantly on any path | σ from daily changes in the 1y yield; `a` fixed in config |
| EURUSD | **Lognormal** with drift = r_USD − r_EUR | Consistent with interest-rate parity, so forwards price correctly | Volatility from 3y of daily log returns |
| WTI crude | **Schwartz one-factor**: log price mean-reverts, d(ln S) = κ(α − ln S)dt + σ·dW | Commodities mean-revert because supply responds to price; forwards have a closed form | AR(1) regression on 10y of daily log prices |
| Dependence | Correlated normal shocks (Cholesky decomposition) | Standard and transparent | Correlation of daily factor moves over 3y |
| Credit | Constant hazard rate from rating-bucket spreads; oil-linked hazard for the wrong-way risk test | Proxy-spread approach, as used for illiquid names | Latest ICE BofA OAS |

---

## Regulatory context

| Rule | What it covers | Where it shows up here |
|---|---|---|
| **SA-CCR** (BCBS 2014; Basel Framework CRE52; US 12 CFR 217.132) | Standardised EAD for derivatives. Replaced the Current Exposure Method. Required for US advanced-approaches banks; other US banks may elect it. | `05` |
| **IMM** (Basel Framework CRE53) | Internal-model EAD = α × EEPE, with ongoing backtesting required | `04` (EEPE), `06` (backtesting) |
| **CCR backtesting** (BCBS 2010, Sound practices) | Backtest the risk factors and the portfolio exposure against realised outcomes | `06` |
| **CVA capital** (BCBS 2020; Basel Framework MAR50) | BA-CVA (standardised) or SA-CVA (sensitivity-based, FRTB-style). The old internal-model CVA approach was removed. | `05` (BA-CVA reduced) |
| **IRB** (Basel Framework CRE31–32) | Vasicek-based capital for default risk. Final Basel III restricts large corporates and banks to Foundation IRB (supervisory LGD 45% for financials, 40% for other corporates). | `05` |
| **Fair value accounting** (IFRS 13; ASC 820) | CVA and DVA are part of derivative fair value and hit P&L | `05` |
| **Model risk management** (Fed SR 11-7) | Independent validation, ongoing monitoring, outcomes analysis | `03` pricing checks, `06` |

**Implementation status (as of mid-2026; check before quoting):**
- **US:** agencies re-proposed the Basel III endgame rules on 19 March 2026.
- **EU:** applies the final Basel package through CRR3, with FRTB and CVA pieces phased to 2027.
- **UK:** PRA Basel 3.1 starts 1 January 2027.

---

## How to explain this project

> "I built a counterparty exposure engine for a small derivatives book: swaps, FX forwards and oil swaps with four counterparties. I calibrate a Hull-White rates model to today's Treasury curve, a lognormal FX model and a Schwartz mean-reverting oil model, with correlated shocks. On 5,000 paths I reprice every trade monthly, net by counterparty, and model CSA collateral with a 10-day margin period of risk. That gives EE and PFE profiles. From EE I compute CVA using spread-implied default probabilities, and I show wrong-way risk: an oil-long fund's CVA rises when its default risk is tied to falling oil, while an airline with the same trade direction shows right-way risk. I compare SA-CCR with the simulation-based EAD and compute IRB and BA-CVA capital. To validate, I check that at-market trades price to zero, run martingale tests, check Monte Carlo convergence, and backtest the risk-factor forecasts against history."

**Follow-up questions to prepare for:**
- **Why is a swap's exposure profile hump-shaped?** Uncertainty grows over time, while the remaining cash flows shrink.
- **Why doesn't collateral remove all exposure?** The margin period of risk, thresholds, MTAs and gap risk at close-out all leave some behind.
- **Real-world or risk-neutral measure: which do you use for PFE, and which for CVA?**
- **Why can SA-CCR be far above the internal-model EAD?** Supervisory factors are conservative and ignore the portfolio's actual dynamics.
- **What is DVA, and why is it controversial?** A bank books a gain when its own credit worsens.

---

## Limitations

**Market data and models**
- One Treasury curve is used for discounting and forwarding. Production uses a SOFR OIS curve plus a separate EUR curve.
- Hull-White mean reversion is fixed rather than calibrated to swaption volatilities.
- Oil forwards come from the model, not NYMEX futures, so the at-market pricing check proves internal consistency only.
- AR(1) estimates overstate mean reversion in finite samples.
- The wrong-way risk link strength is an assumption.
- Bond-index spreads stand in for CDS.

**Pricing and collateral**
- Swaps are valued clean: the current floating coupon and accrued interest are ignored.
- Collateral is variation margin only, with the threshold and MTA combined, which leaves a small permanent residual exposure. There is no initial margin.

**Validation**
- The PIT backtest uses zero drift, so it tests the volatility assumptions rather than the risk-neutral drifts used for CVA.

---

## References

**Methodology**
- Brigo, D. & Mercurio, F. (2006). *Interest Rate Models: Theory and Practice* (2nd ed.). Springer. Hull-White bond prices and simulation.
- Canabarro, E. & Duffie, D. (2003). Measuring and marking counterparty risk. In L. Tilman (Ed.), *Asset/Liability Management of Financial Institutions*. Euromoney Books.
- Diebold, F., Gunther, T. & Tay, A. (1998). Evaluating density forecasts with applications to financial risk management. *International Economic Review*, 39(4), 863–883.
- Glasserman, P. (2003). *Monte Carlo Methods in Financial Engineering*. Springer.
- Gordy, M. (2003). A risk-factor model foundation for ratings-based bank capital rules. *Journal of Financial Intermediation*, 12(3), 199–232.
- Gregory, J. (2020). *The xVA Challenge: Counterparty Risk, Funding, Collateral, Capital and Initial Margin* (4th ed.). Wiley.
- Hull, J. & White, A. (1990). Pricing interest-rate-derivative securities. *Review of Financial Studies*, 3(4), 573–592.
- Hull, J. & White, A. (2012). CVA and wrong-way risk. *Financial Analysts Journal*, 68(5), 58–69.
- Hull, J. *Options, Futures, and Other Derivatives*. Pearson. Chapters on credit risk, CVA and interest rate models.
- Pykhtin, M. & Zhu, S. (2007). A guide to modelling counterparty credit risk. *GARP Risk Review*, July/August 2007.
- Schwartz, E. (1997). The stochastic behavior of commodity prices: implications for valuation and hedging. *Journal of Finance*, 52(3), 923–973.
- Vasicek, O. (2002). The distribution of loan portfolio value. *Risk*, 15(12), 160–162.

**Regulation and standards**
- BCBS (2005). [An explanatory note on the Basel II IRB risk weight functions](https://www.bis.org/bcbs/irbriskweight.htm).
- BCBS (2010). [Sound practices for backtesting counterparty credit risk models](https://www.bis.org/publ/bcbs185.htm).
- BCBS (2014). [The standardised approach for measuring counterparty credit risk exposures](https://www.bis.org/publ/bcbs279.htm) (SA-CCR).
- BCBS (2017). [Basel III: Finalising post-crisis reforms](https://www.bis.org/bcbs/publ/d424.htm).
- BCBS (2020). [Targeted revisions to the credit valuation adjustment risk framework](https://www.bis.org/bcbs/publ/d507.htm).
- [Basel Framework](https://www.bis.org/basel_framework/), chapters CRE31–32 (IRB), CRE50–53 (counterparty credit risk), MAR50 (CVA risk).
- Board of Governors of the Federal Reserve System & OCC (2011). [SR 11-7: Supervisory Guidance on Model Risk Management](https://www.federalreserve.gov/supervisionreg/srletters/sr1107.htm).
- US capital rule: 12 CFR Part 217 (SA-CCR at §217.132). EU: Regulation (EU) 2024/1623 (CRR3). UK: PRA Policy Statement PS1/26.
- IFRS 13 *Fair Value Measurement*; FASB ASC 820 *Fair Value Measurement*.
- ISDA 2002 Master Agreement and ISDA Credit Support Annex.

**Data**
- Federal Reserve Bank of St. Louis, [FRED](https://fred.stlouisfed.org/): Treasury CMT yields (H.15), EURUSD (H.10), ECB deposit rate, WTI spot (EIA), ICE BofA corporate OAS indices (ICE Data Indices, LLC; used with FRED's terms).
- S&P Global Ratings, annual global corporate default and rating transition studies (for long-run PD by rating).
