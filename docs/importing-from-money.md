# Importing from Microsoft Money

MacMoney imports `.mny` files from Microsoft Money 2005 through Money Plus Sunset Edition. The import has two stages:

```
your.mny ──(copy)──► temp copy ──[ mny-export (Java, read-only) ]──► export.json ──[ MoneyImporter (Swift) ]──► MacMoney store
```

1. **`mny-export`** (`tools/mny-export/`) opens a *copy* of the file read-only and writes a neutral JSON document. All knowledge of Money's internal schema lives in this one Java file, [`MnyExport.java`](../tools/mny-export/src/MnyExport.java).
2. **`MoneyImporter`** (`App/MacMoney/Import/MoneyImporter.swift`) merges that JSON into the MacMoney store.

Your original file is never opened for writing.

## Requirements

- A Java runtime, version 8 or later. MacMoney finds it with `/usr/libexec/java_home`. Install one with `brew install openjdk` or from any JDK vendor.
- The converter is bundled inside the app. Xcode builds it with `tools/mny-export/build.sh`, which downloads these pinned libraries from Maven Central and verifies their SHA-1 checksums:

| Library | Version | Purpose |
|---|---|---|
| Jackcess | 4.0.5 | Reads Jet/Access databases, which is what a `.mny` file is |
| Jackcess Encrypt | 4.0.2 | Money's MSISAM encryption |
| Bouncy Castle | 1.78.1 | Crypto provider for the above |
| Commons Lang 3, Commons Logging | 3.14.0, 1.3.0 | Jackcess dependencies |

## Using it

**File ▸ Import from Microsoft Money…** (⇧⌘I), then choose the file. If the file has a password, you'll be asked for it.

The import:

1. takes a **"Before import" backup** of your current MacMoney data;
2. copies the `.mny` to a temporary folder and runs the converter on the copy;
3. merges the result and shows a summary: counts inserted, updated and removed, plus a per-account comparison of MacMoney's reconciled balance against the one Money stored. A check mark means they agree to the cent.

You can also run the converter by hand, for example to inspect the data:

```sh
cd tools/mny-export && ./build.sh
java -jar mny-export.jar "/path/to/My Money.mny" export.json [password]
```

## What's imported

| Money | MacMoney |
|---|---|
| Accounts (bank, credit card, investment, loan), including closed ones | Accounts. Closed accounts are read-only. |
| Opening balance, open date, last reconciled date and balance, account number, comment | Same fields |
| Category tree (income and expense roots, sub-categories) | Categories, shown as `Parent : Child` |
| Payees, including hidden ones | Payees |
| Register transactions: date, amount, number, payee, category, memo, cleared status, cleared date, void | Entries |
| Split transactions | Parent entry plus ordered split lines |
| Transfers | Linked entries in both accounts |
| Flags, with comment and follow-up date | Flag, note and action date |
| Recurring bills & deposits: amount, payee, category, account, frequency, next due date, end date or number of remaining payments | Bills |

Not imported yet: investment holdings and prices, loan amortization schedules, budgets, reports, and attachments. Investment and loan accounts come in with their cash transactions.

## Re-import rules

Re-importing is designed for running Money and MacMoney side by side:

- **Matching:** every imported record keeps its Money ID (`moneyId`). On re-import, records are matched by that ID and updated in place, so nothing is duplicated.
- **Money wins for Money's own fields:** the date, amount, payee, memo, status and so on of a Money record are refreshed from Money.
- **Deleted in Money means deleted here:** Money records that are no longer in the file are removed.
- **Your additions are kept.** Anything created in MacMoney has no Money ID and is never touched, and neither are app-only fields on Money records:
  - business, personal, tax line, business-use %, vehicle tags
  - a category's Schedule C line
  - an account's business link and notes
  - presets, vehicles and mileage logs
- **Flags:** a Money flag on a transaction that's already reconciled is not shown, because MacMoney clears flags on reconcile, as Money's register does.

## Checking the result

- The **import summary** compares reconciled balances per account.
- **File ▸ Check Data File…** looks for duplicates, broken transfers and splits that don't add up.
- In the sidebar, each account's balance should match Money's account list (Money shows the ending balance, including future-dated entries).

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| "Java was not found" | Install a JDK (`brew install openjdk`) and try again. |
| Wrong password / can't open | Make sure Money is closed on the PC and the file isn't a `.mbf` backup. Restore the backup in Money first, then copy the `.mny`. |
| One account's reconciled balance differs from Money's | Money sometimes stores a stale "last reconciled balance". Compare the account's cleared balance with Money's register. |
| A huge balance on a credit card account | Usually only the payments were ever entered in Money (no charges), so the balance shows the payments' total. |
| Flags you set in Money are missing | Re-import. Flags are read from Money's `XBAG` table on every import. |

## Format details

The converter's JSON format (`"format": "macmoney-export"`, version 1) and what we learned about Money's tables are documented in **[Money File Format Notes](money-file-format.md)**.
