# Risk Analytics in R: Market Risk and Counterparty Credit Risk

Two end-to-end risk workflows risk teams at banking or trading houses would run. Both are built from scratch in R on real public data, with backtesting, validation, outputted summary reports and regulatory context.

---

## Table of contents

- [Workflows](#workflows)
- [How to use and run](#how-to-use-and-run)
- [Data sources](#data-sources)
- [How each workflow is organised](#how-each-workflow-is-organised)
- [Repository layout](#repository-layout)
- [Design choices](#design-choices)
- [Key references](#key-references)
- [Disclaimer](#disclaimer)

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
# 1. Open risk-analytics-r.Rproj in RStudio (sets the working directory to the repo root)
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
risk-analytics-r/
├── README.md                 this file
├── setup.R                   install packages
├── run_all.R                 run both workflows
├── make_pdfs.R               turn both reports into styled PDFs
├── risk-analytics-r.Rproj    RStudio project (sets working directory)
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
