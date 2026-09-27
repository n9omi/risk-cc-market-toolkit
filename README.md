# Risk Toolkit: Market Risk and Counterparty Credit Risk Case Studies in R

Two end-to-end case studies that reproduce the daily work of a bank or trading-firm risk team. Each one pulls real market data, cleans it, runs the models, checks them against history, and writes a summary report. Everything is built from scratch in R, with no black-box risk packages, so every number can be traced back to readable code.

**1. Market risk: "How much could this portfolio lose tomorrow, and can we trust that number?"**
Takes a $10mm multi-asset portfolio (US stocks, Treasuries, gold, crude oil, natural gas, and a short energy-stock hedge) and:
- estimates next-day **Value-at-Risk (VaR)** and **Expected Shortfall (ES)** six different ways, from simple historical replay to fat-tailed Monte Carlo
- breaks risk down by position, showing which holdings drive losses and which act as hedges
- finds the worst 12-month period in history for this portfolio (**stressed VaR**)
- **backtests** each model against actual daily P&L since 2008, using the tests regulators use (Kupiec, Christoffersen, the Basel traffic light)
- replays real crises (2008, COVID, negative oil) and hypothetical shocks on today's positions
- estimates capital under **Basel 2.5** and the newer **FRTB** rules

**2. Counterparty credit risk: "If a trading partner defaults, how much could we lose, and what should that risk cost?"**
Takes a book of interest-rate swaps, FX forwards and oil swaps with four counterparties, and:
- simulates 5,000 possible paths for rates, EUR/USD and oil over the next 10 years, and revalues every trade along each path
- measures **exposure**, meaning how much each counterparty could owe us over time, before and after netting and collateral
- prices default risk as **CVA** (credit valuation adjustment), including **wrong-way risk**, where a counterparty is most likely to default exactly when it owes us the most
- calculates regulatory exposure and capital under **SA-CCR**, **IRB** and **BA-CVA**
- validates the models: pricing checks, martingale tests, Monte Carlo convergence, and backtests of the forecasts against history

**What you get:** each case study writes a report of tables, charts, plain-English findings and regulatory notes, generated from the results so it stays accurate when the data updates. See the PDFs under [Reports](#reports).

**Who it's for:**
- **Risk and quant hiring managers:** a working demonstration of the core toolkit behind market risk, counterparty risk and xVA roles, including the validation and documentation that model risk teams expect.
- **Students and career-switchers:** a readable, commented reference implementation of standard methods (Jorion, Hull, Gregory, Basel texts) that you can run and modify through one config file.
- **Analysts** who want a template for a reproducible risk pipeline: data pull, data-quality checks, models, backtests and an auto-generated report.

---

## Table of contents

- [Reports and highlights](#reports)
- [Workflows](#workflows)
- [How to use and run](#how-to-use-and-run)
- [Data sources](#data-sources)
- [How each workflow is organised](#how-each-workflow-is-organised)
- [Repository layout](#repository-layout)
- [Design choices](#design-choices)
- [Key references](#key-references)
- [Disclaimer](#disclaimer)

---

## Reports

📄 **[Market Risk Summary (PDF)](reports/market_risk_summary.pdf)** · 📄 **[Counterparty Credit Risk Summary (PDF)](reports/ccr_summary.pdf)**

Both reports are generated automatically by the code in this repo, using real market data. Click a link to read it in GitHub's PDF viewer.

### Highlights: market risk (as of 2026-09-25)

A $10mm multi-asset book with a commodity tilt (equities, Treasuries, gold, oil, natural gas, short energy-equity hedge).

| Result | Value |
|---|---|
| 1-day 99% historical VaR / 97.5% ES | **$122.7k** (1.12% of gross) / **$137.9k** |
| Tail shape | Historical ES/VaR = 1.12 vs ~1.00 under a normal distribution, so the tail is fatter than normal |
| Diversification benefit | **$221.2k** versus adding up standalone VaRs; the short XLE position is a hedge (−2% of VaR) |
| Stressed VaR (Basel 2.5) | Worst 1-year window Apr 2019 – Apr 2020 (COVID); sVaR **$377.9k**, 3.1× today's VaR |
| Out-of-sample backtest (2008 onward) | Historical simulation: 72 exceptions vs 46 expected (rejected). Filtered HS: 57 vs 46 (right count, but exceptions cluster) |
| Worst stress scenario | 2008 Lehman replay: **−$1.76mm**, 14.4× VaR |

### Highlights: counterparty credit risk (valuation date 2026-09-18)

Seven swaps, FX forwards and WTI swaps with four counterparties; 5,000 Monte Carlo paths.

| Result | Value |
|---|---|
| Largest peak PFE (95%) | Airline C, **$9.01mm** after 0.7 years (no collateral agreement) |
| Collateral effect | Bank A peak PFE $3.09mm → **$953k** with the CSA; Fund D $8.87mm → $6.76mm (the $5mm threshold limits the benefit) |
| Total CVA | **$165.3k**; the largest charge is Airline C (BB, uncollateralised) at $80.5k |
| Wrong-way risk | Linking credit to oil raises Fund D's CVA **+60%** (wrong-way) and cuts Airline C's **−42%** (right-way), with the same trade direction for both |
| SA-CCR vs simulated EAD | **$35.49mm vs $9.55mm**; the standardised approach is ~3.7× more conservative |
| Regulatory capital | IRB RWA $23.78mm + BA-CVA RWA $25.29mm = **$49.07mm** |
| Validation | At-market trades reprice to ~0; 8/8 martingale tests pass; CVA Monte Carlo error < 2%. The rates backtest finds tails too thin: an honest model limitation, documented in the report |

The same reports in web format, regenerated on every run: [market risk](market-risk/outputs/market_risk_summary.md) · [counterparty credit risk](counterparty-credit-risk/outputs/ccr_summary.md)

---

## Workflows

| Workflow | Question it answers | Core outputs | Details |
|---|---|---|---|
| **Market risk** | How much could this portfolio lose tomorrow, and can we trust that number? | VaR and ES six ways, component VaR, stressed VaR, Basel 2.5 / FRTB capital, VaR backtests, stress tests | [market-risk/README.md](market-risk/README.md) |
| **Counterparty credit risk** | How much could we lose if a trading counterparty defaults, and what does that cost? | Exposure simulation (EE, PFE, EEPE), collateral, CVA, wrong-way risk, SA-CCR, BA-CVA and IRB capital, model backtests | [counterparty-credit-risk/README.md](counterparty-credit-risk/README.md) |

---

## How to use and run

**Prerequisites:** R 4.1 or newer, RStudio (recommended), and an internet connection on the first run.

```r
# 1. Open risk-cc-market-risk-toolkit-v1.Rproj in RStudio (sets the working directory to the repo root)
# 2. Install packages once
source("setup.R")
# 3. Run both workflows end to end (a few minutes on the first run while data downloads)
source("run_all.R")
# 4. Optional: save both reports as styled PDFs (uses Chrome or Edge)
source("make_pdfs.R")
```

- **Optional FRED API key:** FRED data downloads without a key. If you have one, run `file.edit("~/.Renviron")`, add a line `FRED_API_KEY=your_key`, and restart R. The key stays on your machine and is never committed. Get a free key at [fredaccount.stlouisfed.org](https://fredaccount.stlouisfed.org/apikey).
- **Step by step:** you can instead run a workflow one script at a time, in numbered order. Each workflow README lists the exact commands.
- **Changing assumptions:** edit `config.R` inside each workflow folder to change the portfolio, trades, confidence levels or model settings.
- **Publishing:** after the first run, commit the `outputs/` folders so the reports and charts show on GitHub. `data/` is git-ignored.

| After running, open | Contents |
|---|---|
| `market-risk/outputs/market_risk_summary.md` | Market risk report |
| `counterparty-credit-risk/outputs/ccr_summary.md` | Counterparty credit risk report |
| `*/outputs/*_summary.pdf` | PDF versions (after `make_pdfs.R`) |

---

## Data sources

All sources are free and need no API key.

| Source | Series | Used in |
|---|---|---|
| Yahoo Finance (via `quantmod`) | Adjusted prices: SPY, TLT, GLD, USO, UNG, XLE | Market risk |
| FRED (St. Louis Fed) | VIX, 10y Treasury yield | Market risk |
| FRED | Treasury yields 1m–30y, EURUSD, ECB deposit rate, WTI spot, ICE BofA corporate spreads by rating | Counterparty credit risk |

- **Optional FRED API key:** if you have a free key, put `FRED_API_KEY=your_key` in your `~/.Renviron` (never in the code) and restart R. The scripts will then use the official FRED API. Without a key, they download FRED's public CSVs.
- **Caching:** downloads are cached in each workflow's `data/raw/` and refreshed at most once a day. If a download fails, the cached copy is used.
- **Data-quality log:** every cleaning fix is written to `outputs/tables/`.

---

## How each workflow is organised

Both workflows follow the same five steps a risk team works through:

| Step | Market risk | Counterparty credit risk |
|---|---|---|
| **1. Pull data** | `01_data_pull.R` | `01_data_pull.R` |
| **2. Clean and prepare** | `02_clean.R`: DQ checks, hypothetical P&L | `02_clean_and_calibrate.R`: DQ checks, curve, model calibration |
| **3. Model** | `03_risk_metrics.R`: VaR, ES, component VaR, sVaR | `03_trades_and_pricing.R`, `04_exposure_simulation.R`, `05_cva_and_capital.R` |
| **4. Backtest and validate** | `04_backtest.R`, `05_stress_test.R` | `06_backtest_and_validate.R` |
| **5. Report** | `06_report.R` | `07_report.R` |

---

## Repository layout

```
risk-cc-market-risk-toolkit-v1/
├── README.md                 this file
├── setup.R                   install packages
├── run_all.R                 run both workflows
├── make_pdfs.R               turn both reports into styled PDFs
├── reports/                  published PDF reports (highlighted above)
├── risk-cc-market-risk-toolkit-v1.Rproj  RStudio project (sets working directory)
├── R/helpers.R               shared: data download + cache, chart theme, formatting
├── R/report.css              PDF styling
├── market-risk/
│   ├── README.md             methods, steps, definitions, references
│   ├── config.R              portfolio and model settings
│   ├── mr_functions.R        VaR/ES estimators, EWMA, component VaR, backtest tests
│   ├── 01_ ... 06_*.R        workflow scripts
│   └── outputs/              tables/ (CSV), figures/ (PNG), market_risk_summary.md
└── counterparty-credit-risk/
    ├── README.md             methods, steps, definitions, references
    ├── config.R              counterparties, CSA terms, trade book, model settings
    ├── ccr_functions.R       curve, Hull-White, Schwartz, pricers, exposure, CVA, SA-CCR, BA-CVA, IRB
    ├── 01_ ... 07_*.R        workflow scripts
    └── outputs/              tables/, figures/, ccr_summary.md
```

---

## Design choices

- **No black boxes.** Every VaR, test statistic, exposure, CVA and capital number is computed in readable code, not by a risk package.
- **Out-of-sample by construction.** Backtests only use data available at the time of each forecast.
- **Validation is built in:**
  - pricing checks
  - martingale tests
  - Monte Carlo convergence
  - coverage and independence tests
  - PIT backtests
- **Every data fix is logged.** Holidays, missing prints, stale prices, and WTI's negative close in April 2020 are all handled and recorded.
- **Reports write themselves.** Observations are generated from the numbers, so they stay correct when data updates.

---

## Key references

Full citations are in each workflow README.

- **Market risk:**
  - Jorion, *Value at Risk*
  - Hull, *Risk Management and Financial Institutions*
  - Kupiec (1995)
  - Christoffersen (1998)
  - Acerbi & Szekely (2014)
  - BCBS FRTB (2019)
  - Fed SR 11-7
- **Counterparty credit risk:**
  - Gregory, *The xVA Challenge*
  - Brigo & Mercurio, *Interest Rate Models*
  - Hull & White (1990, 2012)
  - Schwartz (1997)
  - BCBS SA-CCR (2014)
  - BCBS CVA framework (2020)
  - Basel Framework CRE/MAR chapters

---

## Disclaimer

This is an educational project. The portfolios are hypothetical, and regulatory formulas are implemented for illustration and simplified where noted. Regulatory timelines change, so check current rules before relying on dates.
