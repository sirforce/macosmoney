# Contributing

Thanks for your interest in MacMoney.

## Ground rules

1. **Never commit real financial data.** That includes `.mny` or `.mbf` files, export JSON, `*.store` data files, `*.macmoneybackup` files, screenshots of real accounts, and real names or amounts in tests. `.gitignore` covers the usual files; check `git status` before committing anyway.
2. **Never modify a user's `.mny` file.** The converter must open copies, read-only.
3. **Money is `Int` cents, days are noon-UTC `Date`s.** Use `Cents` and `Day` from `Support/Day.swift`.
4. **Keep models CloudKit-compatible:** defaults or optionals on every attribute, optional relationships, no unique constraints.
5. **Re-import must stay safe.** The importer writes only Money-owned fields. If you add an app-only field, make sure `MoneyImporter` never touches it, and add a check to `testReimportIsIdempotentAndKeepsAppData`.
6. **Large lists use `FastTable`**, not SwiftUI `Table`. Read from `LedgerIndex`, not relationship traversal, in views.

## Setup

```sh
brew install xcodegen openjdk
cd App && xcodegen generate
open MacMoney.xcodeproj
```

Run `xcodegen generate` again whenever you add or remove files or change `project.yml`. The `.xcodeproj` is committed so people without XcodeGen can still build.

## Tests

```sh
cd App
xcodebuild -project MacMoney.xcodeproj -scheme MacMoney -derivedDataPath build/DD test
```

Add tests with **synthetic data** (in-memory `ModelContainer`); see `BillTests` and `ScheduleCTests` for the pattern. Import tests against your own file run when you set `TEST_RUNNER_MACMONEY_EXPORT=/path/to/export.json`.

## App icon and releases

- The icon is drawn in code in `tools/icon/AppIcon.swift`. Run `tools/icon/make-icons.sh` after changing it to regenerate the asset catalog.
- `tools/release/release.sh` builds a signed, notarized app and DMG and installs it. It needs your own Developer ID certificate and a `tools/release/release.env` (git-ignored; copy `release.env.example`). Never commit your team ID or credentials. See [Releasing](docs/releasing.md).
- The version is `MARKETING_VERSION` in `App/project.yml`; release builds number themselves from the git commit count.

## Money format discoveries

If you work out something new about Money's schema (investment lots, loan details, budgets, attachments…), implement it in `tools/mny-export/src/MnyExport.java`, extend the JSON, and document it in [`docs/money-file-format.md`](docs/money-file-format.md). That page is useful to everyone rescuing Money data.

## Style

Follow the surrounding code: small focused types, doc comments on anything non-obvious, and no third-party Swift dependencies.
