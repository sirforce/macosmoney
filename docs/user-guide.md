# MacMoney User Guide

- [The window](#the-window)
- [Accounts](#accounts)
- [Registers](#registers)
- [Importing bank and card downloads](#importing-bank-and-card-downloads)
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

**MacMoney remembers your layout** between runs:

- the window size and position, and the sidebar width;
- the account or page you had open;
- every table's column widths, order and sort column (each table separately);
- each register's view (Unreconciled, All transactions…) and whether the transaction form is showing;
- the Forecast's account, period, custom dates and what-if scenario;
- the period and *show hidden* setting on Payees and on Deposit Sources (each separately).

## Accounts

- **New account:** toolbar **+**. Choose a name, type (bank, credit card, investment, loan), opening balance (enter what you owe on a card or loan as a negative number), date opened, account number, notes and, optionally, the **business** it belongs to.
- **Arrange:** drag accounts up and down in the sidebar to put them in the order you want. Closed accounts can be arranged among themselves. Account pickers elsewhere (transfers, bills, forecast, imports) follow the same order, and new accounts appear at the end until you move them.
- **Edit / Close / Reopen / Delete:** right-click an account in the sidebar.
  - **Closing** keeps the history and makes the account read-only.
  - **Deleting** removes it and all its transactions, after a confirmation. An account that came from Money comes back on the next re-import, so close it instead.
- **Set Balance…** (right-click an account, or **Account ▸ Set Balance…**): enter the balance the bank shows on a date, such as today's balance or a statement's ending balance. The sheet shows what MacMoney has and the difference before anything changes.
  - If nothing in the account came from Money (for example an account filled from a download that only goes back two years), the **opening balance** changes, so all of the history works backward from the balance you entered.
  - If the account has Money history, one reconciled **Balance Correction** is added on that date and the Money history is left as it is.
- For imported accounts, the name and opening balance are refreshed on each re-import. Closing or reopening the account in MacMoney, its place in the sidebar, the business link and notes you set are kept.

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

**Header:** *Today's balance*, *Ending balance* (including future-dated entries), *Cleared balance*, **Balanced through** (the date of the newest reconciled transaction; hover it for the last statement's date and balance), and a flagged-count button that shows just the flagged entries.

**View menu** (toolbar): All transactions · Unreconciled (default) · Flagged · Uncleared · Last 30 days · Last 12 months · This year · Last year · Upcoming.

**Search** (toolbar field): matches memo, payee, number, category, amount or the bank's original description. It always searches the whole account, whatever view is selected. Click in the field and choose **All Accounts** under it to search every account instead (open and closed). The results show each match's account, and double-clicking one opens it in its register. The choice is remembered. **Find Transactions** (⇧⌘F) does the same with extra filters (memo only, period).

**Sorting and columns:** click a column header to sort, and click again to reverse. Drag columns to reorder or resize them; the layout is remembered. Sorting by Date keeps Money's order for entries on the same day.

**Right-click a transaction** for:

- **Show All Transactions for “Payee”:** opens the payee on the Payees page with every transaction from all dates and all accounts. **Return to [account]** in the toolbar (or ⌘[ ) brings you back to the same transaction in the register. This works in closed accounts too.
- **Business:** assign it to a business, mark it personal, or go back to the account's default.
- **Mark As:** Uncleared, Cleared or Reconciled.
- **Add Flag / Clear Flag**, and **Edit Flag…** for the note and action date.
- **Void / Unvoid.**
- **Delete…**, after a confirmation. Deleting one side of a transfer also deletes the other side. You can also press the Delete key.

### Entering and editing transactions

The form at the bottom of the register (toggle it with the toolbar button) handles new and selected transactions:

- **Double-click a cell to edit it.** Double-clicking a transaction's Payee, Date, Category, Num, Memo, Payment, Deposit or **C** cell selects it, shows the form if it's hidden, and puts the cursor in the matching field, ready to type. A double-click on **C** doesn't change the status; it selects the form's status control, where **U**, **C** or **R** (or ← →) change it. Press Return to save.
- **Withdrawal / Deposit / Transfer.** Transfers create the matching entry in the other account and keep both in sync.
- Payee and category fields suggest existing names; typing a new one creates it. Picking a payee fills in the category and amount from its last use.
- The memo can be up to four lines long.
- **Flag** button: when flagged, a row appears for the flag note and an optional action date.
- **Business row:** account default, Personal, or a specific business; Schedule C line override; business-use %; vehicle and expense type.
- Split transactions from Money are displayed with their lines (read-only for now).

### Balancing an account

**Account ▸ Balance Account…** (⇧⌘R), or the ✓ seal button in the register toolbar, works like Money's Balance Account:

1. **Enter the statement.** The starting balance is filled in (opening balance plus everything already reconciled). Enter the statement date and ending balance; for credit cards and loans, enter the amount owed as shown on the statement. Optionally enter a service charge and interest earned with their categories; they're added to the register as cleared transactions.
2. **Check off what cleared.** Unreconciled transactions up to the statement date are listed (tick **Show … after statement date** to include later ones). Click the circle to mark one cleared, or select several and right-click. **Mark All** and **Unmark All** work on the list shown. The footer shows the statement ending balance, the cleared balance and the **difference**. **MacMoney beeps when the difference reaches zero.**
3. **Finish.** Every cleared transaction becomes reconciled (**R**), and their flags clear. If it doesn't balance, Finish offers to add a *Balance Adjustment* transaction for the difference, or you can keep looking.

**Postpone** keeps your marks and the statement figures; next time, the dialog offers to **Resume**.

Balancing done in MacMoney survives re-import: a transaction you reconciled stays reconciled even if Money still shows it as cleared.

## Importing bank and card downloads

**File ▸ Import Bank Files…** (⇧⌘U), or drop downloaded files (or a folder of them) onto the window.

**Supported downloads:** CSV, Excel (`.xlsx`) and OFX/QFX/QBO from most banks. These are recognized automatically:

| Bank | Download |
|---|---|
| Bank of America | Credit card CSV (one per statement, or current activity); checking/savings CSV |
| Chase | Credit card and checking CSV |
| American Express | Card activity CSV or Excel; American Express savings CSV |
| Discover | Online savings "Excel" download (an HTML table) |
| Anything else | OFX/QFX, or a CSV with date, description and amount (or debit/credit) columns |

**How it works:**

1. **Choose where each file goes.** MacMoney suggests an account from what it has learned about the file (the last four digits in its name, the account number inside it, or the folder it's in), so after the first time this is automatic. Files from the same folder move together. Pick a closed account to reopen it, or **New account** to create one named after the folder.
2. **Check the counts.** Each file shows how many rows are **new**, **matched** and **already imported**.
   - *Matched:* the transaction is already in the account, for example a card payment entered from checking. It's linked instead of added.
3. **Balance check (optional).** Enter a statement balance and date. MacMoney adds one reconciled **Balance Correction** so the account agrees with the bank from then on. For a brand-new account it sets the opening balance instead. Discover downloads include the balance, so it's filled in for you.
4. **Import.** A backup is made first. Imported transactions are marked cleared, and payee names are tidied (`AMAZON MKTPL*1A2B3C4D5` becomes **Amazon**). Hover a payee in the register to see the bank's original text. Search finds it too.

**Re-importing is always safe:**

- Import the same file again, a newer file that overlaps an older one, or your whole downloads folder. Only rows MacMoney hasn't seen are added.
- Two identical charges on the same day stay two.
- Anything you add to an imported transaction (category, business, Schedule C line, memo, flag) is never overwritten.
- If you delete an imported transaction, it stays deleted. Importing the file again doesn't bring it back.
- Bank imports are MacMoney's own data, so re-importing from Money leaves them alone.

**Downloads that don't go back to the beginning:** most banks only export a year or two, so an account built from a download can start from the wrong amount. Use the balance check while importing, or **Set Balance…** afterwards, with any balance you know (today's is fine).

**History and undo:** the **History** tab lists every import, with what it added and from which files. **Undo…** removes the transactions an import added, plus its balance correction, and makes a backup first. The files can then be imported again.

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

### Hiding payees and sources

Right-click one or more names in the list and choose **Hide** (or **Unhide**). Hidden names:

- disappear from the list (tick **Hidden**, or right-click ▸ **Show Hidden**, to see them; they're marked *(hidden)*);
- no longer appear as suggestions when you type a payee in a register;
- keep all their transactions. Hiding never changes balances or reports.

Your choice survives re-importing from Money, even if the payee's hidden setting differs in Money.

### Getting around

- **Back / Forward** (toolbar chevrons, **⌘[** / **⌘]**) step through the payees, sources and overview you've viewed, like a web browser.
- The **breadcrumb** at the top of a report ("‹ Income overview › Acme Staffing") returns to the overview in one click.
- **Overview** (toolbar, **⌘0**) or **Show Overview** under the list clears the selection.
- **Opened from a register** (right-click ▸ Show All Transactions): a **Return to [account]** button takes you back to that transaction, and Back goes there once you've stepped back past the first payee.
- **Double-click** a transaction in a payee's list to open it in its register.

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
- **Table:** every event with its source (*actual*, *entered*, *bill*, *overdue*, *what-if*), amount and running balance. **Double-click** an actual or entered transaction to open it in its register.

### What-if scenarios

A scenario is a named set of changes laid over the forecast, so you can see what a decision would do before you make it. Scenarios are projections only: they never change your registers or bills.

**Scenarios…** (in the Forecast toolbar) opens the editor. Add a scenario with **+**, name it, and use **Add Change** for any of:

| Change | Example | You enter |
|---|---|---|
| **One-time amount** | New laptop, tax refund, bonus | Description, money in or out, amount, account, date |
| **New recurring amount** | Car payment, a raise, a new client | Description, money in or out, amount, account, start, how often, optional last date |
| **Change a bill or deposit** | Rent goes up in June | The bill, its new amount, the date it starts |
| **Stop a bill or deposit** | Cancel a subscription, lose a client | The bill, the date it stops |

Double-click a change to edit it; right-click to delete. Right-click a scenario to **Duplicate** it, which is handy for trying variations ("Move in June" vs. "Move in August").

Choose a scenario in the **What-if** menu to see it:

- The chart draws the scenario in **purple** over the normal forecast as a **dashed orange baseline**.
- The ending balance and lowest point show the difference from the baseline (for example "−$4,800.00 vs baseline").
- Transactions the scenario adds or changes are marked *what-if* in the table and hover callouts.

Amounts in accounts outside the forecast's account choice are left out, and dates before today are ignored. The chosen scenario is remembered; choose **None** to go back to the plain forecast.

## Business / Schedule C

See **[Schedule C & Businesses](schedule-c.md)** for the full guide. In short:

1. **Add Business…** in the sidebar.
2. Link business-only accounts to it (edit the account), and/or use **Tag Transactions** to mark business items in mixed accounts.
3. **Tax Line Setup:** map categories to Schedule C lines once.
4. **Vehicles & Mileage:** add vehicles, log trips, choose standard mileage or actual expenses.
5. **Schedule C** and **Profit & Loss** tabs give the reports, with CSV export.

## Purchases

**Purchases** (its own section in the sidebar) lists what you've bought, item by item, whether it was for you or for a business. Marking an item business or personal is how business spending gets onto Schedule C without retyping receipts. The badge shows how many purchases from 2026 on haven't been sorted yet.

**Enter a purchase by hand.** Use this for any store: a music shop, a camera store, a receipt from the counter.

- **From the charge (easiest):** in a register, right-click the card or bank charge ▸ **Itemize Purchase…**. The vendor, date and amount are filled in and the purchase is linked to that charge. Split it into items, and mark each one business or personal as you go. If the items don't add up to the charge, MacMoney shows what's left and offers to add it as *Tax & shipping*.
- **From Purchases:** click **New Purchase** in the toolbar. Choose the charge that paid for it under **Paid with**: nearby charges are listed with the closest amount first. You can also leave it unlinked, for example for a cash receipt.
- **Web links:** add the store's order page or an emailed receipt link in **Link**. **Open Order Page** opens it in your default browser.
- Double-click a purchase you entered (or right-click ▸ **Edit Purchase…**) to change it or delete it. Tags, lines and purposes already set on its items are kept.

**Bring in your Amazon orders**

1. On Amazon, go to **Account ▸ Request Your Data** and request **Your Orders**. Amazon emails a download link.
2. Unzip it, then drag the folder onto the MacMoney window, or click **Import Amazon Orders…** in Purchases. (If you drop it along with bank downloads, Import Bank Files offers **Import into Purchases**.)
3. Each shipment becomes a purchase with its items. Cancelled orders are skipped, digital orders are included, and refunds are noted on the order. Addresses are never read.

Importing a newer export later adds only what's new. Your tags, purposes, notes and links stay as they are.

**Linking to card charges.** Amazon charges your card when each shipment leaves. MacMoney links a shipment to an Amazon charge of exactly the same amount from 2 days before to 5 days after it shipped, preferring the card Amazon says was used. A 🔗 in the list means it's linked. Orders paid partly with a gift card can't match by amount, so link them yourself: right-click ▸ **Link to Charge…** lists nearby charges with the closest amounts first. In a register, a linked charge shows its items in the memo column (when the memo is empty) and in the tooltip; right-click ▸ **Show Purchase** jumps to it.

**Marking items**

- Select one or more items and press **B** for business or **P** for personal (**U** undoes). The buttons at the bottom and the right-click menu do the same.
- The panel on the right sets the **Schedule C line**, **business use %**, a **purpose** and **Returned**. MacMoney suggests a line when you mark an item business: office products, software, books and digital items go to Line 18 (office expense), anything of $2,500 or more to *Equipment / asset purchase* for your accountant to depreciate, and everything else to Line 22 (supplies).
- **Show** filters the list: *Needs review* (the default), *Business*, *Personal*, *Not linked to a charge* or *All*. Only purchases from 2026 on count as needing review. Older history is there for searching.
- With more than one business, **For** chooses which business **B** marks items for.
- Double-click an item to open the charge that paid for it.
- **Hiding:** press **H** (or right-click ▸ **Hide Item**, or tick **Hidden** in the right-hand panel) to tidy away items you never want to see again, such as gifts or old household orders. Hidden items drop out of the list, out of search and out of the review count; a purchase whose items are all hidden no longer needs review. Tick **Show hidden** to see them again (dimmed), then press **H** or choose **Unhide** to bring one back. Hiding doesn't change an item's business tag or any totals.
- **Notes:** each item has its own **Notes** in the right-hand panel; the order has **Order notes**. Search covers item notes.
- **Receipts:** attach any number of files to an item, from anywhere on your Mac: click **Add Receipt…**, or drop files on the right-hand panel. Select several items first to attach the same receipt to all of them.
  - The files stay where they are. MacMoney remembers where they are, not what's in them, so backups don't grow and don't include your receipts. Renaming or moving a file on the same disk is followed automatically.
  - Click 🔍 (or right-click ▸ **Show in Finder**) to open its folder in Finder with the file selected. Double-click a receipt to open it.
  - A 📎 in the list marks items with receipts (a note icon marks items with only notes); click it to show the receipt in Finder.
  - If a file was deleted or moved to another disk, it's shown in orange: **Locate…** points to it again, and **Remove** forgets it.
- **On the web:** Amazon purchases have **View Order on Amazon** and **View Item** (the product page) in the right-hand panel and the right-click menu. They open in your default browser, where you're already signed in. A register charge linked to a purchase has the same choice in its right-click menu.

## Backups and data file checks

See **[Backup & Restore](backup-and-restore.md)**. In short:

- **File ▸ Backups…** (⇧⌘B): back up now, back up to another folder, restore, restore from a file.
- **MacMoney ▸ Settings ▸ Backup:** automatic backups on quit, how often, how many to keep, where (iCloud Drive is one click), and **encryption** with a backup password of your choosing.
- **New Mac:** the Welcome screen's **Restore from Backup** brings everything back. Encrypted backups ask for their backup password.
- **File ▸ Check Data File…:** checks for damage and inconsistencies.

## About MacMoney

**MacMoney ▸ Settings ▸ About** shows the version and build, where your data file and backups are (with **Show in Finder** buttons), the license, and a link to this documentation.

## Keyboard shortcuts

| Shortcut | Action |
|---|---|
| ⇧⌘I | Import from Microsoft Money |
| ⇧⌘F | Find Transactions |
| ⇧⌘B | Backups |
| ⇧⌘R | Balance Account |
| ⇧⌘U | Import Bank Files |
| B / P / U / H | Purchases: mark selected items business / personal / not reviewed; hide or unhide |
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
