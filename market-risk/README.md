# Market Risk: VaR, Expected Shortfall, Backtesting and Stress Testing

> **The question:** how much could this portfolio lose tomorrow, can we trust that number, and what happens in a crisis?

A daily market risk workflow in R: pull real prices, clean them, estimate Value-at-Risk (VaR) and Expected Shortfall (ES) six ways, backtest the models out of sample, stress test the book, and write a summary report.

---

## Table of contents

- [Overview](#overview)
- [How to use and run](#how-to-use-and-run)
- [Data](#data)
- [Workflow steps in plain language](#workflow-steps-in-plain-language)
- [Outputs](#outputs)
- [Key definitions and concepts](#key-definitions-and-concepts)
- [Methods compared](#methods-compared)
- [Regulatory context](#regulatory-context)
- [How to explain this project](#how-to-explain-this-project)
- [Limitations](#limitations)
- [References](#references)

---

## Overview

The portfolio is a hypothetical **$10mm multi-asset book with a commodity tilt**, held as constant dollar positions. Liquid ETFs stand in for each risk factor.

| Ticker | Risk factor | Position |
|---|---|---|
| SPY | US equities | +$4.0mm |
| TLT | Long-dated US Treasuries (interest rates) | +$3.0mm |
| GLD | Gold | +$1.0mm |
| USO | WTI crude oil futures | +$1.5mm |
| UNG | Henry Hub natural gas futures | +$0.5mm |
| XLE | US energy equities (**short**: hedges the oil position) | −$1.0mm |

| Setting | Value | Where to change it |
|---|---|---|
| VaR confidence | 99%, 1-day | `config.R` → `VAR_CONF` |
| ES confidence | 97.5%, 1-day | `ES_CONF` |
| Look-back window | 250 trading days (~1 year) | `WINDOW` |
| EWMA decay | λ = 0.94 (RiskMetrics) | `EWMA_LAMBDA` |
| Monte Carlo | 20,000 scenarios; Student-t with 5 degrees of freedom | `MC_SIMS`, `T_DF` |
| History start | June 2007 (first date all six ETFs trade) | `START_DATE` |

---

## How to use and run

**Prerequisites**
- R 4.1 or newer (the code uses the native pipe `|>`)
- RStudio (recommended)
- An internet connection on the first run

**Run it**

```r
# 1. Open risk-analytics-r.Rproj in RStudio. This sets the working directory to the repo root.
# 2. Install packages (once)
source("setup.R")

# 3a. Run just this workflow, one script at a time, in order
source("market-risk/01_data_pull.R")
source("market-risk/02_clean.R")
source("market-risk/03_risk_metrics.R")
source("market-risk/04_backtest.R")
source("market-risk/05_stress_test.R")
source("market-risk/06_report.R")

# 3b. ...or run both workflows end to end
source("run_all.R")

# 4. Optional: save the report as a styled PDF (uses Chrome or Edge)
source("make_pdfs.R")
```

**Tips**
- **Run from the repo root.** Scripts stop with a clear message if the working directory is wrong.
- **Scripts hand off through files.** Each script saves its results to `data/processed/*.rds`, so after one full run you can re-run any single step without starting over.
- **Change assumptions only in `config.R`:** positions, tickers, confidence levels, windows. Nothing is hard-coded in the scripts.
- **Force a fresh download:** delete `market-risk/data/raw/`. Otherwise data is re-downloaded at most once a day.
- **If a download fails,** the script falls back to the last cached copy and says so in the console.
- **Optional FRED API key:** FRED data downloads without a key. To use your key, run `file.edit("~/.Renviron")`, add the line `FRED_API_KEY=your_key`, save, and restart R. The key stays on your computer and is never committed to GitHub.
- **"SSL certificate problem" error:** your network (often work, university or VPN) is intercepting secure traffic. Switch to home Wi-Fi or a phone hotspot and rerun. You can also download a series by hand from fred.stlouisfed.org (Download → CSV) and save it in `data/raw/` as `SERIESID.csv`; the scripts read it as-is.
- **PDF without Chrome/Edge:** `make_pdfs.R` still writes an `.html` report. Open it in any browser → Print → Save as PDF.
- **Publishing to GitHub:** commit `outputs/` after running so the report and charts render. `data/` is git-ignored.

---

## Data

All sources are free. No API key is required. If `FRED_API_KEY` is set, FRED series come from the official FRED API; otherwise from FRED's public CSV download. Both return the same data.

| Series | Source | Frequency | Used for | Quirks handled |
|---|---|---|---|---|
| SPY, TLT, GLD, USO, UNG, XLE adjusted close | Yahoo Finance via `quantmod::getSymbols` | Daily (trading days) | Returns and P&L for each position | Adjusted for dividends and splits; short gaps filled; stale runs and outliers flagged |
| VIX (`VIXCLS`) | FRED | Daily | Market context | Holidays are blank → carried forward |
| 10-year Treasury yield (`DGS10`) | FRED | Daily | Market context | Holidays are blank → carried forward |

**Data-quality rules** (every fix is logged to `outputs/tables/02_*.csv`)

| Check | Rule | Action |
|---|---|---|
| Non-positive price | Price ≤ 0 | Set to missing |
| Missing price | Gap of 1–2 days | Carry the last price forward |
| Missing price | Longer gap | Drop the date |
| Stale price | 3 or more days of exactly 0% return | Flag for review |
| Outlier | Move larger than 5 × the rolling 1-year standard deviation | **Flag, not delete.** Real crashes are what VaR is for. Each one is checked against the news. |

---

## Workflow steps in plain language

### Step 1: Get the data (`01_data_pull.R`)
1. Download daily prices for the six ETFs, plus VIX and the 10-year yield.
2. Save each series untouched as its own CSV in `data/raw/`. Raw files are never edited.
3. Print a log showing first date, last date and row count for each series.

### Step 2: Clean the data and build P&L (`02_clean.R`)
1. Put all prices into one table: one row per date, one column per ETF.
2. Run the data-quality checks above and write down every fix.
3. Turn prices into daily % returns.
4. Multiply each return by today's position to get daily dollar P&L per position, then add across positions. This is the **hypothetical P&L**: what today's book would have made or lost on each past day.
5. Chart each asset's price history and the daily P&L.

### Step 3: Measure today's risk (`03_risk_metrics.R`)
1. Take the last 250 days of P&L.
2. Estimate 1-day 99% VaR and 97.5% ES six different ways (see [Methods compared](#methods-compared)).
3. Split VaR into each position's contribution (**component VaR**), so you can see what drives risk and what hedges it.
4. Slide a 1-year window across all history to find the worst year for today's book. VaR in that window is the **stressed VaR**.
5. Turn the numbers into illustrative capital: Basel 2.5 (VaR + stressed VaR, times 3) and an FRTB-style liquidity-adjusted ES.
6. Chart the P&L distribution, VaR by method, component VaR, correlations and the stressed window.

### Step 4: Check whether the models worked (`04_backtest.R`)
1. Go back to 2008. For each day, forecast the next day's VaR using only the 250 days before it (no peeking ahead).
2. Compare each forecast with the P&L that actually happened. A day where the loss beats VaR is an **exception**.
3. Count exceptions and run the tests:
   - **Right number of exceptions?** Kupiec test.
   - **Do they cluster?** Christoffersen test.
   - **Regulatory zone?** Basel traffic light.
   - **Is ES big enough?** Acerbi-Szekely Z2.
   - **Would the desk keep internal-model approval?** FRTB desk test.
4. Write a one-line verdict for each model, and chart exceptions over time, the traffic light, and how fast each model reacted to COVID.

### Step 5: Stress test (`05_stress_test.R`)
1. **Historical:** replay eight real crises (Lehman, COVID, negative oil, the 2022 rate shock, and others) on today's positions.
2. **Hypothetical:** apply six made-up instant shocks, such as an equity crash, rates +100bp or an oil supply shock.
3. **Reverse stress test:** ask how far the S&P 500 must fall, with every other asset moving in line with its beta, to lose $1mm.
4. Compare every stress loss to VaR, and chart losses by scenario and by position.

### Step 6: Write the report (`06_report.R`)
1. Collect all results into `outputs/market_risk_summary.md`.
2. Generate the written observations from the numbers, so they stay correct when data updates.

---

## Outputs

| File | What it shows |
|---|---|
| `outputs/market_risk_summary.md` | **Start here.** Full report: tables, charts, observations, regulatory notes |
| `outputs/market_risk_summary.pdf` / `.html` | Styled PDF and web versions of the report (after `make_pdfs.R`) |
| `tables/02_data_quality_summary.csv`, `02_flagged_outliers.csv` | Data-quality checks and flagged moves |
| `tables/03_var_es_by_method.csv` | VaR and ES for all six methods |
| `tables/03_component_var.csv` | Risk contribution by position |
| `tables/03_basel25_capital.csv`, `03_regulatory_summary.csv` | Capital illustrations |
| `tables/04_backtest_results.csv` | Test statistics, p-values, zones, verdicts |
| `tables/04_backtest_daily_forecasts.csv` | Every daily forecast versus realised P&L |
| `tables/05_stress_scenarios.csv`, `05_reverse_stress.csv` | Stress results |
| `figures/*.png` | All charts, numbered by the script that made them |

---

## Key definitions and concepts

| Term | Plain-language definition |
|---|---|
| **Value-at-Risk (VaR)** | The loss that should not be exceeded on 99% of days. 1-day 99% VaR of $100k means you expect to lose more than $100k about 1 day in 100 (~2.5 days a year). |
| **Expected Shortfall (ES)** | The *average* loss on the days worse than VaR. It answers "when it's bad, how bad?" FRTB uses 97.5% ES. |
| **Coherent risk measure** | A risk measure with sensible properties, including **subadditivity**: combining two books never shows more risk than the two separately. ES is coherent; VaR is not always (Artzner et al., 1999). |
| **Hypothetical P&L** | Today's positions revalued with past market moves. It excludes intraday trading, fees and new trades, which isolates what the model predicts. |
| **Actual P&L** | What the desk really made, including trading and fees. FRTB backtests both. |
| **Exception (breach)** | A day where the loss exceeded that day's VaR forecast. |
| **Volatility clustering** | Big moves tend to follow big moves. This is why EWMA and filtered HS react better than equal-weighted windows. |
| **Fat tails** | Extreme moves happen more often than a normal distribution predicts. Visible when historical ES / VaR is noticeably above the normal ratio (~1.0 at these levels). |
| **EWMA** | Exponentially weighted moving average of squared returns. Yesterday gets weight (1−λ), older days decay by λ each day. |
| **Component VaR (Euler allocation)** | Each position's share of total VaR. The shares add up exactly to total VaR. A negative share marks a hedge. |
| **Marginal VaR** | How much VaR changes per extra $1 in a position. |
| **Diversification benefit** | Sum of standalone VaRs minus portfolio VaR. |
| **Stressed VaR (sVaR)** | VaR of today's portfolio calibrated to the worst 12-month period in history (Basel 2.5). |
| **Square-root-of-time rule** | 10-day VaR ≈ 1-day VaR × √10. Only valid if daily returns are independent and identically distributed. |
| **Liquidity horizon** | FRTB's assumed time to exit a position: 10 days (large-cap equity, major rates) up to 120 days. Energy and precious-metal commodities use 20. |
| **Traffic light** | Basel's backtest zones over 250 days of 99% VaR: Green 0–4 exceptions, Yellow 5–9, Red 10+. Yellow and red add a "plus factor" to the capital multiplier. |
| **Kupiec POF test** | A likelihood-ratio test of whether the exception rate equals 1 − confidence. |
| **Christoffersen test** | A likelihood-ratio test of whether an exception today makes one tomorrow more likely. |
| **Conditional coverage** | Kupiec and Christoffersen combined (2 degrees of freedom). |
| **Acerbi-Szekely Z2** | An ES backtest statistic. Its expected value is 0 if ES is right; below about −0.70 means ES is too small. |
| **Stress test** | P&L under a specific extreme scenario. It answers the question VaR can't: how bad is the tail? |
| **Reverse stress test** | Start from a loss amount and find the scenario that causes it. |
| **Beta** | How much an asset moves per 1% move in the market (SPY). |

---

## Methods compared

| Method | How it works | Strength | Weakness |
|---|---|---|---|
| **Historical simulation (HS)** | Sort the last 250 real P&Ls and read off the 1% worst | No distribution assumption; real tails and correlations | Slow to react. A crash drops out abruptly after 250 days. |
| **Parametric normal** | VaR = 2.33 × σ, with σ from the covariance matrix | Fast; easy to decompose | Normal tails are too thin |
| **EWMA normal (RiskMetrics)** | Same, but σ weights recent days more (λ = 0.94) | Reacts within days to a volatility spike | Still normal tails |
| **Filtered HS** | Rescale each past return by (today's vol ÷ vol at the time), then run HS | Real tail shape at today's volatility level | More assumptions and parts |
| **Monte Carlo normal** | Simulate 20,000 correlated normal scenarios | Extends to option books | Converges to the parametric answer for linear books |
| **Monte Carlo Student-t** | Same, with fat-tailed t shocks | Captures fat tails | Tail thickness (degrees of freedom) is an assumption |

---

## Regulatory context

| Rule | What it requires | Where it shows up here |
|---|---|---|
| **Basel 2.5 / US Market Risk Rule** (12 CFR 217 Subpart F) | Capital = max(VaR, 3 × 60-day average VaR) + max(sVaR, 3 × 60-day average sVaR), using 10-day 99% VaR. The multiplier rises with backtest exceptions. | `03` (capital), `04` (traffic light, plus factor) |
| **Basel backtesting framework** (BCBS 1996) | 250 days of 99% VaR exceptions sorted into green, yellow and red zones | `04` |
| **FRTB** (BCBS 2019, MAR30–33) | 97.5% ES with liquidity horizons, stressed calibration, desk-level approval, backtesting at 99% and 97.5%, and a P&L attribution test | `03` (liquidity-adjusted ES), `04` (desk test) |
| **Stress testing** (Fed CCAR/DFAST, 12 CFR 252) | Large US banks apply a supervisory "global market shock" to trading books | `05` |
| **Model risk management** (Fed SR 11-7) | Conceptual soundness, ongoing monitoring and outcomes analysis for every model | `04` is the outcomes analysis |

**Implementation status (as of mid-2026; check before quoting):**
- **US:** agencies re-proposed Basel III endgame, including FRTB, on 19 March 2026.
- **EU:** FRTB capital requirements apply from 1 January 2027 under CRR3.
- **UK:** PRA Basel 3.1 applies from 1 January 2027, with FRTB internal models from 1 January 2028.

---

## How to explain this project

> "I built a daily market risk workflow for a multi-asset book. I pull prices, run data-quality checks, and build hypothetical P&L, which is today's positions revalued with each historical day's moves. I estimate 99% VaR and 97.5% ES six ways and decompose VaR by position with Euler allocation, so I can show which positions drive risk and which hedge it. Then I backtest out of sample: each day's forecast uses only the prior 250 days. I run Kupiec for coverage, Christoffersen for clustering, the Basel traffic light, and Acerbi-Szekely for ES. Finally I stress the book with historical crises and hypothetical shocks, because VaR says nothing about losses beyond the 99th percentile."

**Follow-up questions to prepare for:**
- **Why did regulators move from VaR to ES?** ES captures tail severity and is subadditive.
- **When does √10 scaling fail?** When volatility clusters or returns are autocorrelated.
- **How can a position have negative component VaR?** It's a hedge: adding to it lowers portfolio VaR.
- **Why do HS exceptions cluster in 2008 and 2020?** The window is slow to absorb a new volatility regime.
- **Hypothetical versus actual P&L: what's the difference, and why backtest both?**

---

## Limitations

- ETFs proxy the risk factors. A real book maps positions to curves, spreads and volatility surfaces.
- The positions are linear, so there are no option Greeks (gamma, vega).
- USO and UNG returns include futures roll yield, not just spot moves.
- 10-day figures use √10 scaling.
- The FRTB calculation is simplified: no stressed-period calibration or reduced risk-factor set.
- The Basel 2.5 capital illustration uses a multiplier of 3; the backtest plus factor is reported separately.
- Stress scenarios span several weeks, but they are compared with 1-day VaR for scale only.

---

## References

**Methodology**
- Artzner, P., Delbaen, F., Eber, J.-M. & Heath, D. (1999). Coherent measures of risk. *Mathematical Finance*, 9(3), 203–228.
- Acerbi, C. & Tasche, D. (2002). On the coherence of expected shortfall. *Journal of Banking & Finance*, 26(7), 1487–1503.
- Acerbi, C. & Szekely, B. (2014). Backtesting expected shortfall. *Risk*, December 2014.
- Christoffersen, P. (1998). Evaluating interval forecasts. *International Economic Review*, 39(4), 841–862.
- Hull, J. & White, A. (1998). Incorporating volatility updating into the historical simulation method for value-at-risk. *Journal of Risk*, 1(1), 5–19.
- J.P. Morgan / Reuters (1996). *RiskMetrics: Technical Document* (4th ed.).
- Kupiec, P. (1995). Techniques for verifying the accuracy of risk measurement models. *Journal of Derivatives*, 3(2), 73–84.
- Tasche, D. (1999). Risk contributions and performance measurement. Working paper, TU München.

**Textbooks**
- Hull, J. *Risk Management and Financial Institutions*. Wiley. Chapters on VaR, ES, model building and backtesting.
- Jorion, P. (2007). *Value at Risk: The New Benchmark for Managing Financial Risk* (3rd ed.). McGraw-Hill.
- McNeil, A., Frey, R. & Embrechts, P. (2015). *Quantitative Risk Management* (rev. ed.). Princeton University Press.

**Regulation and supervisory guidance**
- BCBS (1996). [Supervisory framework for the use of "backtesting" in conjunction with the internal models approach to market risk capital requirements](https://www.bis.org/publ/bcbs22.htm).
- BCBS (2009). [Revisions to the Basel II market risk framework](https://www.bis.org/publ/bcbs158.htm) (Basel 2.5).
- BCBS (2019). [Minimum capital requirements for market risk](https://www.bis.org/bcbs/publ/d457.htm) (FRTB). Consolidated in the [Basel Framework](https://www.bis.org/basel_framework/), chapters MAR10–MAR33 and MAR99.
- Board of Governors of the Federal Reserve System & OCC (2011). [SR 11-7: Supervisory Guidance on Model Risk Management](https://www.federalreserve.gov/supervisionreg/srletters/sr1107.htm).
- US Market Risk Rule: 12 CFR Part 217, Subpart F.
- EU: Regulation (EU) 2024/1623 (CRR3). UK: PRA Policy Statement PS1/26 (Basel 3.1).

**Data**
- Yahoo Finance (via the `quantmod` R package).
- Federal Reserve Bank of St. Louis, [FRED](https://fred.stlouisfed.org/): series `VIXCLS`, `DGS10`.
