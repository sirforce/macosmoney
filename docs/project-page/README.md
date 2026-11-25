# MacMoney: project page details

This folder is the source for the MacMoney page on the portfolio site. `project.json` has the same content in structured form; see [Sample Data, Screenshots and the Project Page](../demo-and-screenshots.md) for how it's kept up to date.

> Every screenshot shows invented sample data. No real person, account or amount appears.

**A native macOS replacement for Microsoft Money.**

MacMoney is a native Mac app for people who still keep their finances in Microsoft Money Plus Sunset Edition. It imports a Money file with its whole history, keeps the way Money works (registers, flags, bills and deposits, payee reports, forecasting) and adds what Money never had: safe bank-download imports, item-level purchases, what-if scenarios and Schedule C tracking for a home business.

![Forecast chart with a what-if scenario line dipping below the dashed baseline](../screenshots/forecast-what-if.png)

| | |
|---|---|
| **Status** | Pre-release, version 0.11 |
| **Platform** | macOS 26 (Tahoe) or later |
| **License** | MIT |
| **Role** | Solo project: design, development and documentation |
| **Source** | https://github.com/sirforce/macosmoney |
| **Built with** | Swift, SwiftUI, SwiftData (SQLite), AppKit (NSTableView), Swift Charts, ScreenCaptureKit, CryptoKit / CommonCrypto, Java (Jackcess) for the Money file converter, XcodeGen, XCTest |

## Why it exists

Microsoft Money was discontinued years ago and only runs on Windows. MacMoney reads the .mny file directly, read-only, and brings in accounts, categories, payees, transactions, splits, transfers, flags and recurring bills. Importing again is safe, so Money and MacMoney can run side by side until the switch is final.

From there it is a full personal-finance app. Bank and card downloads go in without ever adding a transaction twice. Registers reconcile against statements. A forecast projects balances from bills and deposits, and what-if scenarios show what a decision would do before it is made. One or more sole-proprietor businesses can be tracked through their own accounts or tagged inside personal ones, producing a draft Schedule C.

Everything stays on the Mac. The app makes no network connections, the data is a standard SQLite file, and backups are verified and can be encrypted.

## In numbers

| | |
|---|---|
| Swift in the app | about 13,000 lines |
| Unit tests | 68 |
| Data models | 19 |
| Network connections | 0 |
| Register rows shown without lag | 10,000+ |

## Features

### Import from Microsoft Money

Reads .mny files from Money 2005 through Sunset Edition, including password-protected ones, without modifying them.

- Accounts, categories, payees, transactions, splits, transfers, flags and recurring bills
- Re-import as often as you like: Money's records update in place and everything added in MacMoney is kept
- The import summary compares every account's balance with what Money stored, to the cent
- A backup is taken before every import

### Bank and card downloads

CSV, Excel and OFX/QFX from Bank of America, Chase, American Express, Discover and most other banks.

- Drop a file or a whole folder; each file finds its account from what the app learned last time
- Nothing is ever added twice, even from overlapping files
- Payments already entered by hand are matched instead of duplicated
- Edits are kept and deleted rows stay deleted on re-import
- Payee names are tidied; the bank's original text is kept and searchable
- Optional balance check, import history, and undo for every import

### Registers

One register per account, built to feel like Money's.

- Running balance, cleared and reconciled status, voids, transfers and splits
- Flags with a note and an action date
- Balance Account reconciles against a statement and beeps at zero; sessions can be postponed
- Filters (Unreconciled, Flagged, Upcoming, date ranges) and search in one account or all of them
- Double-click a cell to edit that field; Return saves; undo and redo for register changes
- Bank, credit card, loan and investment accounts, with Set Balance and drag-to-order

### Purchases

What was bought, item by item, linked to the charge that paid for it.

- Import a whole Amazon order history; shipments link to their card charges automatically
- Itemize any charge by hand, from any store
- Press B or P to mark items business or personal, with a Schedule C line, business-use % and purpose
- Notes, web links and receipt files (referenced where they are, never copied)

### Find, Payees and Deposit Sources

Search everything, and see where money goes and where it comes from.

- Find across every account, open or closed
- Per-payee trend chart, totals by year and by category, every transaction, CSV export
- Select several payees at once; save selections and filters as presets
- Back and forward navigation between reports

### Bills & Deposits

Recurring items that keep their day of the month.

- Weekly, every other week, twice a month, monthly, quarterly, yearly and more
- Enter, skip, or pre-load everything due into the right registers
- Transfer bills post to both accounts
- Optional auto-pay flag on entered items

### Forecast and what-if scenarios

A balance projection that never double counts, plus named scenarios laid over it.

- Today's balance + entries made ahead + bills not yet entered
- 3 to 36 months or a custom range, for one account or all bank accounts
- Hover the chart to see what moves the balance each day
- Scenarios: one-time or recurring amounts, changed or stopped bills, drawn against the baseline with the difference shown

### Business / Schedule C

Bookkeeping for one or more sole-proprietor businesses, including a home-based one.

- Link whole accounts to a business, or tag individual transactions in mixed personal accounts
- Map categories to Schedule C lines once
- Business-use percentages (for example 40% of home internet), 50% meals
- Asset list with each year's depreciation, entered from the accountant's schedule, feeding line 13
- Vehicles with a trip log: standard mileage or actual expenses
- Schedule C and profit & loss per business or for all, with CSV for the accountant

### Backup, restore and data checks

Built so the data file can be trusted.

- Verified point-in-time backups, manual or automatic on quit
- Optional AES-256 encryption and iCloud Drive folder
- A safety backup before every import and every restore
- Check Data File looks for database damage and bookkeeping inconsistencies
- Backups made by older versions restore into newer ones, checked by a test

## Technical highlights

**Reading a format with no specification.** A Money file is an encrypted Jet database with an undocumented schema. A small bundled Java converter (built on Jackcess) opens a copy read-only and writes JSON; the app decodes that and merges it. The schema notes worked out along the way are published in the repository.

**Re-import that is always safe.** Every record from Money carries its Money id, and the importer writes only Money-owned fields. App-owned fields (business tags, tax lines, notes, presets) live separately, so importing the same file a hundred times changes nothing and loses nothing.

**Bank imports that never duplicate.** Each bank row gets a fingerprint (the bank's reference, or date + amount + normalized description, with an occurrence number so two identical same-day charges stay two). Fingerprints are remembered even after the transaction is edited or deleted. Rows that match something already in the register within a week are linked rather than added.

**Exact money, stable dates.** Amounts are integer cents everywhere; there is no floating point where money is added up. Dates are calendar days stored at noon UTC, so a transaction never changes day when the time zone does.

**Fast with decades of history.** Views never walk the SwiftData relationship graph. A ledger index keeps plain value rows, built once at launch (about 0.6 s for 8,000 entries) and patched from save notifications (about 40 ms). Large lists use a custom NSTableView wrapper with fixed row heights instead of SwiftUI's Table, which froze for seconds on 7,500 rows; it shows them in about 5 ms.

**Backups you can rely on.** Backups use SQLite's online backup API, so they are consistent while the app is running, and each one is integrity-checked after it is written. Encrypted backups use PBKDF2-HMAC-SHA256 and AES-256-GCM in authenticated 1 MB chunks. Restores are staged and applied before the store is opened, after a safety copy of the current data.

**Private by construction.** The app makes no network connections. Receipts are referenced by bookmark, not copied. The data is a standard SQLite file in Application Support that the owner can open with any tool.

**Ready for iCloud sync.** All 19 models follow CloudKit's rules from the start (defaults or optionals on every attribute, optional relationships, no unique constraints), with identity carried by a uuid.

**Screenshots without real data.** A built-in demo mode generates five years of an invented household from a seeded generator. The app photographs its own window screen by screen, and every picture is read back with OCR and rejected if the developer's name or home folder appears in it. The pictures on this page were made that way.

## Screenshots

### Registers

**Account register.** A checking register with running balance, cleared and reconciled marks, flags with notes, transfers, and the transaction form underneath. A briefcase marks transactions that count toward a business.

![MacMoney checking account register with a transaction selected and its details in the form below](../screenshots/register-checking.png)

**Credit card register.** Card charges brought in from a bank download, with payee names tidied up and Amazon charges showing the items that were bought.

![Credit card register listing recent charges with categories and linked purchase items](../screenshots/register-credit-card.png)

**Loan register.** An auto loan paying down: each month's interest charge and the payment transferred from checking.

![Auto loan register showing monthly interest and payments](../screenshots/register-auto-loan.png)

**Balance Account.** Reconciling against a statement. Tick off what cleared; the difference counts down and the app beeps when it reaches zero.

![Balance Account sheet with cleared transactions ticked and the remaining difference shown](../screenshots/balance-account.png)

### Bank and card downloads

**Import bank files.** Drop a folder of downloads. Each file is matched to its account, and shows how many rows are new, already in the register (matched) or already imported.

![Import Bank Files sheet listing four downloads with new, matched and already imported counts](../screenshots/bank-import.png)

**Import history and undo.** Every import is recorded with what it added and matched, and can be undone.

![Import history listing two past imports with Undo buttons](../screenshots/bank-import-history.png)

### Purchases

**Purchases to review.** Item-level purchases from an Amazon order export. Press B or P to mark an item business or personal.

![Purchases list showing unreviewed Amazon items](../screenshots/purchases-review.png)

**An itemized purchase.** A camera bought for the business, entered by hand from the card charge: each item has a Schedule C line, a business-use percentage and a purpose.

![Purchases view with three items selected and their business details in the side panel](../screenshots/purchases-itemized.png)

### Find and reports

**Find Transactions.** One search across every account, open or closed, with the match count and net total.

![Find Transactions results across several accounts](../screenshots/find-transactions.png)

**Payees overview.** Where the money went: totals, a monthly average, the top payees and their share.

![Payees overview with a stacked bar chart by year and a ranked list of payees](../screenshots/payees-overview.png)

**Payee report from a saved preset.** Four utilities selected with one click from a saved preset: a chart over time, totals by year and every transaction, ready to export.

![Payee report for four utility companies with chart and yearly totals](../screenshots/payees-report.png)

**Deposit Sources.** The same report for money coming in, here for the freelance business's clients.

![Deposit Sources report for five clients with yearly totals](../screenshots/deposit-sources.png)

### Planning

**Bills & Deposits.** Recurring bills, deposits and transfers with their next due dates. One is overdue; the car payment's schedule is open on the right.

![Bills and Deposits list with one bill selected and its schedule in the inspector](../screenshots/bills-and-deposits.png)

**Forecast.** Twelve months of projected balance from today's balance, entries already made ahead of time and bills not yet entered, with no double counting.

![Forecast chart of account balances over the next twelve months with the list of upcoming events](../screenshots/forecast.png)

**What-if scenario.** A new roof laid over the baseline forecast: the purple line is the scenario, the dashed line is what would have happened, and the summary shows the difference.

![Forecast chart with a what-if scenario line dipping below the dashed baseline](../screenshots/forecast-what-if.png)

**Scenario editor.** A scenario is a named set of changes: stop a deposit, change a bill, add a one-time or recurring amount. Nothing in the registers changes.

![Scenario editor listing three scenarios and the changes in one of them](../screenshots/scenarios.png)

### Business and Schedule C

**Schedule C.** A draft Schedule C for a sole-proprietor business, line by line, with the vehicle worksheet underneath and a CSV export for the accountant.

![Schedule C report with income, expense lines and net profit](../screenshots/schedule-c.png)

**Profit & Loss.** Income and expenses by category for the year, with a month-by-month chart.

![Profit and loss report with category totals and a monthly bar chart](../screenshots/profit-and-loss.png)

**Tag Transactions.** For business activity that runs through personal accounts: filter, select and tag transactions with a business, a tax line and a business-use percentage.

![Tag Transactions table with business and tax line columns](../screenshots/tag-transactions.png)

**Vehicles & Mileage.** A trip log per vehicle, with the standard mileage rate or actual expenses.

![Vehicle mileage log listing business trips with miles and purpose](../screenshots/vehicles-and-mileage.png)

**Assets and depreciation.** Equipment the business depreciates over several years, with each year's amount entered from the accountant's schedule. The year's total goes on Schedule C line 13.

![Assets tab listing four business assets with cost, depreciation and remaining value, and one asset's yearly amounts](../screenshots/assets.png)

**Tax Line Setup.** Map each category to a Schedule C line once; it applies to every year and every business.

![Tax Line Setup listing categories and their Schedule C lines](../screenshots/tax-line-setup.png)

**All Businesses.** Gross income, expenses and net profit side by side when there is more than one business.

![All Businesses summary table for two businesses](../screenshots/all-businesses.png)

### Safety

**Backups.** Verified point-in-time backups, manual or automatic on quit, optionally encrypted.

![Backups sheet listing backups with Back Up Now and Restore buttons](../screenshots/backups.png)

**Check Data File.** Looks for database damage and bookkeeping inconsistencies: broken transfers, splits that don't add up, duplicates.

![Check Data File sheet reporting no problems found](../screenshots/check-data-file.png)

### Getting started

**Welcome.** First launch: import a Microsoft Money file, or restore a backup when moving to a new Mac.

![Welcome screen offering to import from Microsoft Money or restore from a backup](../screenshots/welcome.png)

## Roadmap

1. Purchases on Schedule C: a business purchases report by line, for the accountant
2. Purchase rules: vendor and department defaults so new imports arrive already tagged
3. Card and bank follow-ups: link card payments to the checking payments that paid them, payee cleanup rules, a business review queue
4. Smaller purchase items: hide a whole order, attachments on any register transaction
