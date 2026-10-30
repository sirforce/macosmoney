# Architecture

MacMoney is a SwiftUI + SwiftData app for macOS 26, plus a small Java command-line converter for Money files.

```
┌──────────────────────────── MacMoney.app ────────────────────────────┐
│  Views (SwiftUI)  ── FastTable (NSTableView) for large lists          │
│        │                                                              │
│  LedgerIndex (@Observable value cache) ◄── ModelContext.didSave       │
│        │                                                              │
│  Support: EntryStore · BillStore · Forecast · ScheduleCReport ·       │
│           Backup · DataCheck · Day/Cents                              │
│        │                                                              │
│  SwiftData models ──► ~/Library/Application Support/MacMoney/*.store  │
│        ▲                                                              │
│  MoneyImporter ◄── export.json ◄── mny-export.jar (bundled, run via   │
│                                     /usr/bin/java on a temp copy)     │
└───────────────────────────────────────────────────────────────────────┘
```

## Code layout

| Path | What's there |
|---|---|
| `App/project.yml` | XcodeGen spec. A pre-build script builds the converter jar when it's missing or stale. No sandbox, because the app runs `java`. |
| `App/MacMoney/MacMoneyApp.swift` | App entry: model container, a restore pending from the last session, menu commands, Settings, and the backup on quit |
| `Models/Models.swift` | `Account`, `Category`, `Payee`, `Entry`, `Bill`, `ImportRecord`, `ReportPreset` |
| `Models/BusinessModels.swift` | `Business`, `Vehicle`, `MileageEntry`, `TaxLine`, `VehicleExpense`, mileage rates |
| `Import/` | `MoneyExportFile` (Decodable JSON, plus running the converter) and `MoneyImporter` (upsert and removal) |
| `Support/LedgerIndex.swift` | Flat, sorted value rows for every entry, plus per-account totals and payee usage |
| `Support/EntryStore.swift`, `BillStore.swift` | Create, edit and delete entries (keeping transfer peers in sync), and bill recurrence |
| `Support/Forecast.swift` | Cash-flow projection |
| `Support/ScheduleC.swift` | Schedule C and vehicle worksheet |
| `Support/Backup.swift`, `DataCheck.swift` | Snapshots, staged restore, integrity checks |
| `Support/Day.swift` | Calendar-day and money helpers |
| `Views/FastTable.swift` | Generic NSTableView wrapper |
| `Views/…` | One file per screen |

## Data model conventions

- **Money is stored as `Int` cents.** There's no floating point anywhere money is added up. `Cents.parse` is exact.
- **Dates are calendar days**, stored as **noon UTC** and handled with a UTC calendar (`Day`). That avoids time-zone and daylight-saving shifts changing a transaction's day.
- **CloudKit-compatible from day one**, ready for iCloud sync later:
  - every attribute has a default or is optional;
  - no `@Attribute(.unique)`;
  - every relationship is optional.

  Identity is a `uuid` property; Money records also carry `moneyId`.
- **Money-owned and app-owned fields are separate.** The importer only writes fields that come from Money. App-only fields (business tags, tax lines, notes, presets…) are never touched, which is what makes repeated re-import safe.
- **Effective values are computed, not stored.** For example `Entry.effectiveBusiness` (own tag → vehicle → split parent → account) and `effectiveTaxLine` (override → category).

## LedgerIndex: why lists are fast

Going through SwiftData relationships (`entry.payee?.name`, `entry.account?.name`) for thousands of rows on every redraw is slow. `LedgerIndex` keeps a cache of plain value structs (`EntryRow`) instead:

- **At launch:** one `FetchDescriptor<Entry>` sorted by date. Names are resolved once, then rows are sorted by small keys (date, then Money's same-day order). This takes about 0.6 s for ~8,000 entries.
- **When data is saved:** it listens for `ModelContext.didSave` on the main context and patches only the changed entries, using the inserted, updated and deleted identifiers (about 40 ms). Changes to models that don't affect rows (bills, presets, mileage) are ignored. Other changes, such as renaming an account or payee, trigger a full rebuild.
- **Exposes:**
  - `rows` and `rowsByAccount`
  - `totals` (today, ending and cleared balances)
  - `payeeUsage`
  - name lists for autocomplete
  - a `version` counter that views use as a `.task(id:)` key

Views read the index, never the relationship graph, and call `EntryStore` to make changes.

## FastTable: why tables don't freeze

SwiftUI's `Table` on macOS measures every inserted row (automatic row heights). Switching a register to "All transactions" (7,500+ rows) blocked the main thread for seconds. `FastTable` wraps `NSTableView` instead:

- **Fixed row height**, and views are made only for visible rows and reused.
- **Sorting:** clicking a header uses each column's comparator. Sorting happens in the coordinator, so the caller hands over rows in their natural order.
- Column widths and order are saved (`autosave`). Supports a right-click menu built from `FastMenuItem`, double-click, the Delete key, single-click actions per column (the register's flag and C columns), and SF Symbol cells.
- Selection is a `Set<ID>` binding. Changing it from outside scrolls the table to the selected row. `scrollKey` re-applies the initial scroll (registers start at the newest entry).
- `sizeThatFits` claims the space it's offered, because an `NSScrollView` has no natural size.

Building and showing 7,500 rows takes about 5 ms.

## Forecast

`Forecast(accounts:bills:today:horizon:historyFrom:)`:

1. **Starting balance:** each account's balance as of today.
2. **Entered ahead:** register entries dated after today, up to the horizon.
3. **Bills:** each active bill's occurrences from its **next due date** (`Bill.occurrences(through:)`). Occurrences already entered have advanced the next due date, so nothing is counted twice. Overdue occurrences are moved to today. Transfer bills affect both accounts.
4. **Running balance:** events sorted by date, money out before money in on the same day, giving step-curve points.
5. **History:** actual entries from `historyFrom` to today, with running balances, for the grey line and custom ranges.

`BalanceCurve` merges history and forecast for the chart, with a binary-search balance lookup and nearest-day snapping for hover.

## Import

`MoneyImporter.run(_:)`:

1. Upsert accounts, categories (two passes for parents), payees, then entries. A second pass links split parents and transfer peers.
2. Upsert bills: a bill's day of the month comes from its start date; a finished series becomes inactive.
3. Delete records whose `moneyId` is gone from the export.
4. Return a summary with per-account reconciled balances compared against Money's.

`importMny(at:)` wraps the whole pipeline: backup first, copy the file to a temp folder, run `java -jar mny-export.jar`, decode, then run.

## Backups

- `Backup.make` uses `sqlite3_backup_*` to copy the live store into a new file, switches the copy out of WAL mode so it's a single file, checks it with `PRAGMA integrity_check`, then prunes old copies.
- **Restore is staged.** The chosen file is recorded in user defaults and the app relaunches. `applyPendingRestore()` runs in `MacMoneyApp.init` before the `ModelContainer` exists: it backs up the current store, swaps in a fresh copy of the backup, and removes `-wal` and `-shm`.

## Testing

`App/MacMoneyTests`:

| Test file | Covers |
|---|---|
| `ImportTests` | Real export, optional: reconciled balances match Money, flag rules, re-import is idempotent and keeps app data |
| `BillTests` | Day-of-month anchoring, end dates, entering advances the bill, flags clear on reconcile, the forecast doesn't double count, transfer bills |
| `ScheduleCTests` | Mixed and business accounts, business %, 50% meals, transfers excluded, standard vs. actual vehicle methods |
| `BackupTests` | Round trip, restore with safety copy, pruning, rejecting non-backup files, data file check |
| `PresetAndCurveTests` | Preset round trip, forecast curve snapping and balances |
| `LedgerIndexTests`, `CentsTests` | Index matches the model and incremental updates are fast; money parsing; date round trips |

Tests that need personal data read it from environment variables (`TEST_RUNNER_MACMONEY_EXPORT`) and skip otherwise. No real data is ever committed.
