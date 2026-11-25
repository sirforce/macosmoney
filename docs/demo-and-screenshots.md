# Sample Data, Screenshots and the Project Page

Everything public about MacMoney (the README pictures, the project page on the portfolio site) is made from **invented sample data**, never from a real data file. This page explains how that works and how to refresh it when a feature is added.

## Sample data mode

```sh
open MacMoney.app --args --demo
```

| Argument | What it does |
|---|---|
| `--demo` | Opens the sample household instead of your data. It's created the first time and kept after that, so you can change things and come back. |
| `--demo-reset` | Starts over with fresh sample data. |
| `--demo-empty` | Starts with no data at all (the Welcome screen). |
| `--demo-tour=<folder>` | Walks through every screen and saves a picture of each, then quits. |

**Your real data is never opened.** In demo mode:

- the data file is `~/Library/Application Support/MacMoney Demo/MacMoney.store` (or the folder in `MACMONEY_DEMO_DIR`). A folder that is the real data folder is refused;
- backups go to that folder's own `Backups`, whatever Settings ▸ Backup says, and there is no automatic backup on quit;
- a restore waiting for the next launch is left for the next normal launch.

Layout preferences (window size, column widths, the last page open) are shared with the normal app unless the app is built with its own bundle id, which is what the screenshot script does.

### The household

`App/MacMoney/Demo/DemoData.swift` builds it. Nothing in it comes from a real person: the people, employer, clients and shops are made up, and amounts come from a seeded random generator, so every run gives the same household. It always ends today and starts on January 1 four years back.

| | |
|---|---|
| **Accounts** | Joint Checking, Emergency Savings, Rewards Visa, Studio Checking, Studio Visa, Auto Loan, Mortgage, Index Fund, and a closed Credit Union Checking |
| **Income** | A paycheck every other Friday with yearly raises and a December bonus; savings interest; dividends |
| **Home** | Mortgage with monthly interest, property tax, insurance, HOA dues by check, utilities that follow the seasons, preschool that ends and an after-school club that begins |
| **Events** | A car bought in the second year (down payment from savings, then a 60-month loan), a furnace replaced in the third winter, a summer trip each July, one voided check |
| **Cards** | About 45 charges a month, paid in full each month. The last few weeks arrive as bank downloads (see below) |
| **Juniper Lane Studio** | A freelance design business with its own checking account and card: a retainer client, project clients, contract labor, software, advertising, client meals, a yearly conference, a camera bought as equipment, a vehicle with a mileage log, four depreciating assets, and a business share of the home internet (40%) and phone (50%) |
| **Tidepool Prints** | A second, smaller business run through the personal accounts, to show tagging in a mixed account and cost of goods sold |
| **Purchases** | An Amazon order for almost every Amazon charge, with items tagged business or personal (the newest ones left to review), plus two purchases entered by hand |
| **Planning** | 25 bills and deposits (one overdue), two payments entered ahead and flagged, three what-if scenarios, saved presets on Payees and Deposit Sources |

**Bank downloads.** `Sample Downloads/` in the demo folder holds two files per card (a Chase-style CSV and a QFX). The older one of each was imported when the data was made, through the real importer, so the import history, the bank's original text and the cleaned-up payee names are real. The newer one overlaps it. Drop the folder on the window to see *new*, *matched* and *already imported* counts.

`DemoDataTests` checks that the household is complete, that no bank account ever goes negative, that every transfer has both sides, that the downloads behave as described and that the data is the same every time.

## Taking the screenshots

```sh
tools/demo/screenshots.sh              # every screen → docs/screenshots/
tools/demo/screenshots.sh forecast,bills-and-deposits   # just these
```

The script:

1. builds the app with the bundle id `io.github.macmoney.MacMoney.demo`, so it has its own preferences;
2. runs the tour on fresh sample data in `/tmp/macmoney-demo` (a neutral path, because the Backups screen shows where the data is), then once more with no data for the Welcome screen;
3. **checks every picture**: `tools/demo/check-screenshots.swift` reads each one back (OCR) and stops the run if your user name, full name or home folder shows up anywhere. Add your own words to look for, such as your real bank or employer, with `MACMONEY_PRIVATE_WORDS="Word One,Word Two"`;
4. copies the pictures to `docs/screenshots/` at 1920 pixels wide.

The window comes to the front for about a minute and a half while it runs. Pictures are taken by the app itself, of its own window only (ScreenCaptureKit's current-process content), so nothing else on the screen can appear in one and no screen-recording permission is needed.

### Adding a screen

1. Add a `DemoScene` to `DemoTour.scenes` in `App/MacMoney/Demo/DemoTour.swift`. A scene names an account, page or business, and optionally a sheet to open, a transaction or purchase to select, and starting values for views.
2. If the new screen needs a starting state the tour can't reach (a tab, a search, a selection), read it in the view with `DemoTour.preset("your.key")`. It returns nil outside the tour, so normal use is unaffected. `BusinessView`'s tab and `FindView`'s search are examples.
3. If the feature needs data that the household doesn't have yet, add it to `DemoData.swift` and to `DemoDataTests`.
4. Run the script, look at the new picture, and add it to `docs/project-page/project.json` with a caption.

## The project page

`docs/project-page/` is what the portfolio site reads to build the MacMoney page:

| File | What it is |
|---|---|
| `project.json` | Everything in one structured file: summary, status, links, feature groups, capabilities, technical highlights, numbers, roadmap, and each screenshot with a title, caption and alt text |
| `README.md` | The same content written out, for reading |
| `../screenshots/*.png` | The pictures `project.json` refers to |

Screenshot paths in `project.json` are relative to the repository root, and `links.rawBase` gives the public URL they can be loaded from once pushed.

**When a feature ships:** update the sample data if needed, add a scene, run `tools/demo/screenshots.sh`, then update `project.json` (a feature entry, a screenshot entry, `version`, `updated`, and `stats` if they changed) and the README's feature table. The site picks up the rest.
