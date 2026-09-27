# =============================================================================
#  make_pdfs.R  |  Turn both summary reports into styled PDFs
# =============================================================================
#
#  Run AFTER run_all.R:   source("make_pdfs.R")
#
#  What it does
#    1. Converts each report (.md) into a single self-contained web page (.html)
#       with the charts embedded and the styling from R/report.css
#    2. Prints that page to PDF using the Chrome or Edge browser already on
#       your computer (no LaTeX needed)
#
#  Output
#    market-risk/outputs/market_risk_summary.pdf
#    counterparty-credit-risk/outputs/ccr_summary.pdf
#    (plus the matching .html files, which open in any browser)
#
#  Needs: rmarkdown (comes with RStudio, which also bundles pandoc) and
#  Google Chrome or Microsoft Edge installed.
# -----------------------------------------------------------------------------

if (!file.exists("R/helpers.R")) stop("Run from the repo root (open risk-analytics-r.Rproj).")
for (p in c("rmarkdown")) {
  if (!requireNamespace(p, quietly = TRUE)) install.packages(p, repos = "https://cloud.r-project.org")
}
if (!rmarkdown::pandoc_available()) {
  stop("pandoc not found. Run this from RStudio (it includes pandoc), or install pandoc.")
}

reports <- c(
  "Market Risk Summary"                = "market-risk/outputs/market_risk_summary.md",
  "Counterparty Credit Risk Summary"   = "counterparty-credit-risk/outputs/ccr_summary.md"
)
css <- normalizePath("R/report.css")


# ---- Find Chrome or Edge ----------------------------------------------------
# Uses pagedown's finder if that package is installed, otherwise checks the
# usual install locations on Mac, Windows and Linux.
find_browser <- function() {
  if (requireNamespace("pagedown", quietly = TRUE)) {
    b <- tryCatch(pagedown::find_chrome(), error = function(e) "")
    if (nzchar(b)) return(b)
  }
  candidates <- c(
    "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
    "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge",
    "/Applications/Chromium.app/Contents/MacOS/Chromium",
    file.path(Sys.getenv("PROGRAMFILES"),       "Google/Chrome/Application/chrome.exe"),
    file.path(Sys.getenv("PROGRAMFILES(X86)"),  "Google/Chrome/Application/chrome.exe"),
    file.path(Sys.getenv("LOCALAPPDATA"),       "Google/Chrome/Application/chrome.exe"),
    file.path(Sys.getenv("PROGRAMFILES(X86)"),  "Microsoft/Edge/Application/msedge.exe"),
    file.path(Sys.getenv("PROGRAMFILES"),       "Microsoft/Edge/Application/msedge.exe"),
    Sys.which(c("google-chrome", "google-chrome-stable", "chromium", "chromium-browser", "microsoft-edge"))
  )
  hit <- candidates[nzchar(candidates) & file.exists(candidates)]
  if (length(hit)) hit[1] else ""
}

# Print an HTML file to PDF with the browser in headless (no window) mode
html_to_pdf <- function(html, pdf, browser) {
  url <- paste0("file://", ifelse(.Platform$OS.type == "windows", "/", ""),
                gsub("\\\\", "/", normalizePath(html)))
  args <- c("--headless", "--disable-gpu", "--no-sandbox",
            "--no-pdf-header-footer", "--print-to-pdf-no-header",
            paste0("--print-to-pdf=", normalizePath(pdf, mustWork = FALSE)),
            url)
  system2(browser, shQuote(args), stdout = FALSE, stderr = FALSE)
  file.exists(pdf)
}


# ---- Build each report -------------------------------------------------------
browser <- find_browser()
if (!nzchar(browser)) {
  message("Chrome/Edge not found: HTML reports will be made, but not PDFs.\n",
          "  To get a PDF: open the .html file in any browser -> Print -> Save as PDF.")
}

for (title in names(reports)) {
  md <- reports[[title]]
  if (!file.exists(md)) {
    message("Skipping ", title, ": ", md, " not found. Run run_all.R first.")
    next
  }
  message("Building: ", title)

  html <- rmarkdown::render(
    input = md,
    output_format = rmarkdown::html_document(
      self_contained = TRUE,      # charts embedded, so the file stands alone
      theme = NULL, highlight = NULL, mathjax = NULL,
      css = css,
      md_extensions = "-tex_math_dollars",   # "$" means dollars here, not math
      pandoc_args = c("--metadata", paste0("pagetitle=", title))
    ),
    output_file = sub("\\.md$", ".html", basename(md)),
    output_dir  = dirname(md),
    quiet = TRUE
  )
  message("  saved ", html)

  if (nzchar(browser)) {
    pdf <- sub("\\.html$", ".pdf", html)
    ok <- html_to_pdf(html, pdf, browser)
    message(if (ok) paste("  saved", pdf) else
            "  PDF step failed: open the .html in a browser -> Print -> Save as PDF.")
  }
}

message("\nDone. PDFs are in each workflow's outputs/ folder.")
