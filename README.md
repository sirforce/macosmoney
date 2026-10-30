# MacMoney

**Version 0.9** (pre-release)

A native macOS replacement for **Microsoft Money Plus Sunset Edition**. It imports your `.mny` file with its whole history and keeps the way Money works: registers, flags, bills & deposits, payee reports and forecasting. It also adds things Money never had, such as Schedule C tracking for one or more sole-proprietor businesses.

Money was discontinued years ago and only runs on Windows. MacMoney lets you move to the Mac without losing twenty years of transactions. Because re-importing is safe, you can keep running both side by side until you're ready to switch.

> MacMoney is an independent project. It is not affiliated with or endorsed by Microsoft. "Microsoft Money" is a trademark of Microsoft Corporation.

## Features

| Area | What you get |
|---|---|
| **Import from Money** | Reads `.mny` files from Money 2005 through Sunset Edition (read-only). Brings in accounts, categories, payees, transactions, splits, transfers, flags and recurring bills. Re-import as often as you like: Money's records update in place and anything you added in MacMoney is kept. |
| **Bank & card downloads** | Import CSV, Excel and OFX/QFX downloads from Bank of America, Chase, American Express, Discover and most other banks. Drop a file or a whole folder. Re-import as often as you like: nothing is added twice, your edits are kept, deleted rows stay deleted, and payments already in the account are matched instead of duplicated. Every import can be undone. |
| **Registers** | One register per account with running balance, cleared/reconciled status (click to toggle), flags with a note and action date, voids, transfers and split display. **Balance Account** reconciles against a statement and beeps when the difference reaches zero. View filters include Unreconciled, Flagged, Uncleared, date ranges and Upcoming. Search covers memo, payee, number and amount. Fast with 10,000+ rows. |
| **Accounts** | Bank, credit card, investment and loan accounts. Create, edit, close (read-only) or delete them. Closed Money accounts import as read-only history. |
| **Find** | Search every transaction in every account, with a "memo only" option and period filter. Double-click a result to jump to it in its register. |
| **Payees & Deposit Sources** | Every payee, or only the people and companies who pay you, with use counts, this year's and all-time totals. Select one or many for a trend chart, totals by year and category, every transaction, and CSV export. Back and forward buttons move between what you've looked at. **Saved presets** recall a selection and its filters with one click. |
| **Bills & Deposits** | Recurring items (weekly, twice a month, monthly, yearly and more) that keep their day of the month. Sort, edit the next due date and frequency, enter or skip occurrences, or pre-load everything due into the right register. Optionally flag entries as "auto-pay scheduled". |
| **Forecast** | Today's balance, plus entries you've already entered ahead of time, plus bills and deposits not yet entered, without double counting. Choose 3–36 months or a custom date range. **What-if scenarios** (one-time or recurring amounts, changed or stopped bills) are drawn over the baseline with the difference shown. Hover the chart to see what moves the balance each day; click to highlight those transactions; double-click to open one. |
| **Business / Schedule C** | One or more businesses. Link whole accounts, or tag individual transactions in a personal account where business and personal are mixed. Map categories to Schedule C lines. Supports business-use %, 50% meals and vehicles (standard mileage or actual expenses with a trip log). Produces a Schedule C and a profit & loss report per business or for all of them, with CSV for your accountant. |
| **Backup & restore** | Verified point-in-time backups: manual, automatic when the app quits (each time, daily, weekly or monthly), keep the last *N*, optionally **AES-256 encrypted** and optionally in iCloud Drive. A safety backup is taken before every import and every restore. **Check Data File** looks for database damage and bookkeeping inconsistencies. |

See the **[User Guide](docs/user-guide.md)** for a full walkthrough.

## Requirements

- macOS 26 (Tahoe) or later
- Xcode 26 and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`) to build
- A Java runtime, version 8 or later, to import `.mny` files (`brew install openjdk`, or any JDK). Not needed once your data is imported.

## Build and run

```sh
git clone <this repo> && cd macosmoney/App
xcodegen generate                 # creates MacMoney.xcodeproj from project.yml
xcodebuild -project MacMoney.xcodeproj -scheme MacMoney -configuration Release \
           -derivedDataPath build/DD build
open build/DD/Build/Products/Release/MacMoney.app
```

Or open `App/MacMoney.xcodeproj` in Xcode and press Run. The first build downloads the Money converter's Java libraries from Maven Central and checks their checksums (see [`tools/mny-export/build.sh`](tools/mny-export/build.sh)).

Use the **Release** configuration for day-to-day use; it's much faster with large registers.

To produce a signed, notarized app and DMG and install it in `/Applications`, use `tools/release/release.sh`. See **[Releasing](docs/releasing.md)**.

## Getting your data in

1. In Money on Windows, make sure the file is saved and closed. Copy the `.mny` file to your Mac.
2. In MacMoney choose **File ▸ Import from Microsoft Money…** (⇧⌘I) and pick the file. Password-protected files are supported.
3. The import summary compares each account's balance with what Money stored, so you can check it to the cent.

The original file is copied before it's read and is never modified. Details: **[Importing from Money](docs/importing-from-money.md)**.

## Where your data lives

| What | Where |
|---|---|
| Data file | `~/Library/Application Support/MacMoney/MacMoney.store` (SQLite, via SwiftData) |
| Backups | `~/Library/Application Support/MacMoney/Backups/` by default (configurable, for example iCloud Drive). Optionally encrypted. |
| Backup password | Your login keychain (item "MacMoney backup password") |
| Settings | `defaults read io.github.macmoney.MacMoney` |

Nothing is sent anywhere. The app makes no network connections. The only download happens at build time, when the converter's open-source libraries are fetched.

## Documentation

- [User Guide](docs/user-guide.md): every screen and feature
- [Importing from Money](docs/importing-from-money.md): the converter, re-import rules and troubleshooting
- [Backup & Restore](docs/backup-and-restore.md): automatic backups, restoring, data file checks
- [Schedule C & Businesses](docs/schedule-c.md): setting up businesses, tagging, vehicles, reports
- [Architecture](docs/architecture.md): code layout, data model, performance design
- [Money File Format Notes](docs/money-file-format.md): what we learned about Money's internal schema
- [Releasing](docs/releasing.md): signing, notarizing, the DMG and the app icon
- [Contributing](CONTRIBUTING.md)

## Project layout

```
App/                      SwiftUI + SwiftData macOS app (XcodeGen project in project.yml)
  MacMoney/Models/        Data model (accounts, entries, bills, businesses, presets…)
  MacMoney/Import/        Runs the converter and merges its JSON into the store
  MacMoney/Support/       Ledger index, forecast, Schedule C, backups, date and money helpers
  MacMoney/Views/         Screens; FastTable.swift is the NSTableView-backed list used everywhere
  MacMoneyTests/          Unit tests (import tests use your own export and skip without one)
tools/mny-export/         Read-only Java converter: .mny → JSON (Jackcess)
tools/icon/               The app icon, drawn in code, and the script that renders every size
tools/release/            Release script: sign, notarize, DMG, install
docs/                     Documentation
```

## Tests

```sh
cd App
xcodebuild -project MacMoney.xcodeproj -scheme MacMoney -derivedDataPath build/DD test
```

Most tests use synthetic data. The import tests need a real export and are skipped without one:

```sh
java -jar ../tools/mny-export/mny-export.jar ~/path/file.mny /tmp/export.json
TEST_RUNNER_MACMONEY_EXPORT=/tmp/export.json \
  xcodebuild -project MacMoney.xcodeproj -scheme MacMoney -derivedDataPath build/DD test
```

If Money itself stores a wrong reconciled balance for an account, list it so the balance check skips it: `TEST_RUNNER_MACMONEY_KNOWN_MISMATCHES="Account A,Account B"`.

## Roadmap

Planned, roughly in order:

- **Saved reports** with PDF export (spending by category, income vs. expense, net worth)
- **Attachments**: receipts and statements (images, PDFs) on any transaction
- **Link card payments to checking**, then payee rules, a business review queue for Schedule C, and a spending report
- **iCloud sync** between Macs (the data model is already CloudKit-compatible)
- Payee rules to tag business transactions automatically

## Privacy note for contributors

Never commit real financial data. `.gitignore` excludes `*.mny`, exports, data files, backups and screenshots. Use synthetic data in tests. See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

[MIT](LICENSE) © 2026 Brent Ferree.
