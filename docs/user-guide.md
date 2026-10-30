# MacMoney User Guide

- [The window](#the-window)
- [Accounts](#accounts)
- [Registers](#registers)
- [Flags](#flags)
- [Find Transactions](#find-transactions)
- [Payees and Deposit Sources](#payees-and-deposit-sources)
- [Bills & Deposits](#bills--deposits)
- [Forecast](#forecast)
- [Business / Schedule C](#business--schedule-c)
- [Backups and data file checks](#backups-and-data-file-checks)
- [Keyboard shortcuts](#keyboard-shortcuts)
- [Tips for running alongside Money](#tips-for-running-alongside-money)

---

## The window

The **sidebar** on the left has:

- **Accounts:** open accounts with their current balance. A briefcase means the account belongs to a business.
- **Closed Accounts:** read-only history, collapsed by default.
- **Lists:** Find Transactions, Payees, Deposit Sources, Bills & Deposits.
- **Planning:** Forecast.
- **Business:** your businesses, *All Businesses* (once you have two or more), and *Add Business…*.

The toolbar has **New Account** (+) and **Import from Money**.

## Accounts

- **New account:** toolbar **+**. Choose a name, type (bank, credit card, investment, loan), opening balance (enter what you owe on a card or loan as a negative number), date opened, account number, notes and, optionally, the **business** it belongs to.
- **Edit / Close / Reopen / Delete:** right-click an account in the sidebar.
  - **Closing** keeps the history and makes the account read-only.
  - **Deleting** removes it and all its transactions, after a confirmation. An account that came from Money comes back on the next re-import, so close it instead.
- For imported accounts, the name, opening balance and closed status are refreshed on each re-import. The business link and notes you set in MacMoney are kept.

## Registers

Select an account to open its register.

| Column | Meaning |
|---|---|
| Flag | Red flag = flagged; orange = its action date has arrived. **Click** to flag or clear. |
| **C** | Blank = uncleared, **C** = cleared, **R** = reconciled. **Click** to toggle cleared/uncleared. Reconciled entries change only from the right-click menu. |
| Num | Check number or code (ATM, DEBIT, EFT…). |
| Date | Entries dated after today are greyed (entered ahead of time). |
| Payee | **VOID** is shown in red for voided entries. |
| (briefcase) | The transaction counts toward a business. Hover to see which business and Schedule C line. |
| Category, Memo | Hover the memo to read all of it. |
| Payment / Deposit / Balance | Running balance in date order. Negative balances are red. |

**Header:** *Today's balance*, *Ending balance* (including future-dated entries), *Cleared balance*, the date Money last balanced the account, and a flagged-count button that shows just the flagged entries.

**View menu** (toolbar): All transactions · Unreconciled (default) · Flagged · Uncleared · Last 30 days · Last 12 months · This year · Last year · Upcoming.

**Search** (toolbar field): matches memo, payee, number, category or amount. It always searches the whole account, whatever view is selected.

**Sorting and columns:** click a column header to sort, and click again to reverse. Drag columns to reorder or resize them; the layout is remembered. Sorting by Date keeps Money's order for entries on the same day.

**Right-click a transaction** for:

- **Business:** assign it to a business, mark it personal, or go back to the account's default.
- **Mark As:** Uncleared, Cleared or Reconciled.
- **Add Flag / Clear Flag**, and **Edit Flag…** for the note and action date.
- **Void / Unvoid.**
- **Delete…**, after a confirmation. Deleting one side of a transfer also deletes the other side. You can also press the Delete key.

### Entering and editing transactions

The form at the bottom of the register (toggle it with the toolbar button) handles new and selected transactions:

- **Withdrawal / Deposit / Transfer.** Transfers create the matching entry in the other account and keep both in sync.
- Payee and category fields suggest existing names; typing a new one creates it. Picking a payee fills in the category and amount from its last use.
- The memo can be up to four lines long.
- **Flag** button: when flagged, a row appears for the flag note and an optional action date.
- **Business row:** account default, Personal, or a specific business; Schedule C line override; business-use %; vehicle and expense type.
- Split transactions from Money are displayed with their lines (read-only for now).

## Flags

Flags work like Money's "flag for follow-up":

- Flag or clear by clicking the flag column, from the right-click menu, or with the form's **Flag** button.
- A flag can carry a **note** (for example "auto-pay scheduled 11/1") and an optional **action date**. Edit them with right-click ▸ **Edit Flag…**, or in the form when the transaction is selected.
- A flag turns **orange** once its action date arrives.
- **Flags clear automatically when a transaction is reconciled**, as in Money. On import, Money flags on already-reconciled entries are not shown.
- Bills can flag the entries they create; see [Bills & Deposits](#bills--deposits).

## Find Transactions

**Lists ▸ Find Transactions** (⇧⌘F) searches every account, open or closed. Type at least two characters of any memo, payee, category, number or amount.

- **Memo only** restricts the search to memos.
- The period menu limits the date range.
- The status line shows the number of matches and their net total.
- **Double-click** a result to open it in its register.

## Payees and Deposit Sources

Both pages share a layout: a list on the left and a report on the right.

**Payees** lists every payee. **Deposit Sources** lists only payees who have paid you money (deposits, not transfers between your own accounts).

**The list** has columns for count, last used or last deposit, *This year* and *Total*. Click any header to sort. Search by name, and tick **Hidden** to include payees hidden in Money.

**With nothing selected**, the right side is an overview of the chosen period:

- headline totals, a per-month average and the largest payee or source;
- a bar chart of the top 5 against everyone else;
- the top 15 with share bars. Click a name to select it.

**Select one or more** (⌘-click for several, ⌘A for all) to see:

- headline numbers: total, count, average, per month, largest, and the last date;
- a chart over time, monthly for up to 3 years and yearly beyond that;
- **By year** and **By category** breakdowns;
- every matching transaction, sortable, with **Export CSV**.

### Getting around

- **Back / Forward** (toolbar chevrons, **⌘[** / **⌘]**) step through the payees, sources and overview you've viewed, like a web browser.
- The **breadcrumb** at the top of a report ("‹ Income overview › Acme Staffing") returns to the overview in one click.
- **Overview** (toolbar, **⌘0**) or **Show Overview** under the list clears the selection.

### Presets

Save a selection and its filters (period, custom dates, search text, Hidden) to recall later. Payees and Deposit Sources each have their own presets.

- **Save:** **Presets** menu ▸ *Save as New Preset…*, or **Save Preset…** above the report. Saving under an existing name replaces it.
- **Recall:** click a preset **chip** above the list. Clicking the active chip again clears it.
- **Edited presets:** if you change the selection or filters after recalling, the preset shows *edited*. Choose **Update "name"** to save the change.
- **Rename / Delete:** Presets menu, or right-click a chip.

Presets live in your data file, so they're included in backups.

## Bills & Deposits

**Lists ▸ Bills & Deposits** shows recurring items imported from Money, plus any you create.

- **Sort** by any column; next due date is the default.
- **Edit** in the inspector (toolbar **Details**): payee, account, amount, category, frequency (once, weekly, every *n* weeks, twice a month, monthly, every *n* months, yearly), next due date, end date or number of remaining payments, and **Flag when entered (auto-pay scheduled)**.
- Monthly and yearly bills keep their **day of the month**: a bill due on the 31st falls on the 30th in shorter months and goes back to the 31st afterwards.
- **Enter in Register…** posts the next occurrence into the right account, so you can adjust the amount or date first, then moves the bill to its next due date.
- **Skip This Occurrence** advances the bill without posting anything.
- **Enter Bills Due…** pre-loads every occurrence due up to a date you choose, in one go. Untick any you want to hold back.
- **Transfer bills** (for example a monthly savings transfer) post to both accounts.

## Forecast

**Planning ▸ Forecast** projects your balance:

> today's balance **+** entries already dated after today **+** bill & deposit occurrences not yet entered

Bills you've already entered ahead of time aren't counted twice. Overdue bills you haven't entered are projected on today and called out in orange.

- **Account:** all bank accounts combined, or any single account.
- **Period:** next 3, 6, 12, 18, 24 or 36 months, or **Custom range…** with From and To dates. With a custom range that starts in the past, the chart and table show what actually happened up to today (grey, marked *actual*), then the forecast.
- **Summary:** today's balance, the balance at the end of the period (and at the start, for custom ranges), and the **lowest point**. Click the lowest point to jump to that day.
- **Chart:** grey for actual history, orange for the forecast, a dashed line for today and a red line at zero.
  - **Hover** to snap to the nearest day with activity. A callout shows the day's ending balance, the net change and the transactions behind it.
  - **Click** to highlight that day's transactions in the table below and scroll to them. Selecting a row in the table marks its day on the chart.
- **Table:** every event with its source (*actual*, *entered*, *bill*, *overdue*), amount and running balance. **Double-click** an actual or entered transaction to open it in its register.

## Business / Schedule C

See **[Schedule C & Businesses](schedule-c.md)** for the full guide. In short:

1. **Add Business…** in the sidebar.
2. Link business-only accounts to it (edit the account), and/or use **Tag Transactions** to mark business items in mixed accounts.
3. **Tax Line Setup:** map categories to Schedule C lines once.
4. **Vehicles & Mileage:** add vehicles, log trips, choose standard mileage or actual expenses.
5. **Schedule C** and **Profit & Loss** tabs give the reports, with CSV export.

## Backups and data file checks

See **[Backup & Restore](backup-and-restore.md)**. In short:

- **File ▸ Backups…** (⇧⌘B): back up now, back up to another folder, restore, restore from a file.
- **MacMoney ▸ Settings ▸ Backup:** automatic backups on quit, how often, how many to keep, and where (iCloud Drive is one click).
- **File ▸ Check Data File…:** checks for damage and inconsistencies.

## Keyboard shortcuts

| Shortcut | Action |
|---|---|
| ⇧⌘I | Import from Microsoft Money |
| ⇧⌘F | Find Transactions |
| ⇧⌘B | Backups |
| ⌘[ / ⌘] | Back / Forward (Payees, Deposit Sources) |
| ⌘0 | Overview (Payees, Deposit Sources) |
| ⌘, | Settings |
| ⌘A | Select all (lists) |
| Delete | Delete selected transaction (with confirmation) |
| ⌘-click | Add to selection |

## Tips for running alongside Money

- Keep entering in Money and **re-import** whenever you like. Money's records update in place, and records deleted in Money disappear.
- What you add in MacMoney survives re-import: accounts, payees, transactions, bills, business tags, Schedule C lines, vehicles, presets and flags you set on MacMoney-created entries.
- Changes you make in MacMoney to records that came from Money (amount, payee, memo…) **are overwritten** by the next import. Make those edits in Money until you switch over for good.
- A backup is taken automatically before each import, so you can always go back.
