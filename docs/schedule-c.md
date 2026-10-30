# Schedule C & Businesses

MacMoney tracks income and expenses for one or more **sole-proprietor businesses** and produces a draft **IRS Schedule C** (Profit or Loss From Business) for each, ready to hand to your accountant.

> MacMoney organizes your records; it isn't tax software or tax advice. Have a tax professional review the result.

## Concepts

| Term | Meaning |
|---|---|
| **Business** | A sole proprietorship with its own Schedule C. Add as many as you need. |
| **Business account** | An account linked to a business. Everything in it counts toward that business unless marked personal. |
| **Mixed account** | A personal account that also holds business transactions. Tag those transactions individually. |
| **Tax line** | The Schedule C line a transaction belongs on, usually set once per **category**. |
| **Business-use %** | The part of a transaction that's business (for example 50% of a phone bill). |

### Which business does a transaction count toward?

The first of these that applies:

1. the transaction's own **Business** tag (set from Tag Transactions, the register's right-click menu, or the form);
2. its **vehicle's** business;
3. its **split parent's** business;
4. its **account's** business.

A transaction marked **Personal** never counts, even in a business account.

### Which line?

The transaction's own **tax line override**, if it has one; otherwise its **category's** Schedule C line. Transfers between accounts are skipped unless you set a line on them explicitly.

## Setting up

1. **Add Business…** in the sidebar. Enter a name, plus an EIN and notes if you like.
2. **Link accounts** that are business-only: right-click the account ▸ **Edit** ▸ *Business*.
3. **Tax Line Setup** tab: map each category you use for business to a Schedule C line. You only do this once; it applies to every year and every business, and survives re-import from Money.
4. **Tag Transactions** tab, for mixed accounts:
   - Filter by account, period, and a **Show** option: All, Not tagged, This business, This business with no tax line, Marked personal. Search payee, memo or category, and hide transfers.
   - Select rows (⌘A for all), then **Tag as *Business***, **Personal**, **Tax Line**, **Business %**, **Vehicle**, or **Clear Tags** to go back to the account's default.
   - The **Line** column is orange where a business transaction still has no line.

You can also tag one transaction at a time: right-click it in a register ▸ **Business**, or use the business row in the transaction form.

## Schedule C lines

| Part | Lines |
|---|---|
| **I · Income** | 1 Gross receipts · 2 Returns & allowances · 6 Other income |
| **II · Expenses** | 8 Advertising · 9 Car & truck · 10 Commissions & fees · 11 Contract labor · 12 Depletion · 13 Depreciation · 14 Employee benefits · 15 Insurance · 16a Mortgage interest · 16b Other interest · 17 Legal & professional · 18 Office · 19 Pension & profit-sharing · 20a Rent: vehicles & equipment · 20b Rent: other property · 21 Repairs · 22 Supplies · 23 Taxes & licenses · 24a Travel · 24b Meals (50%) · 25 Utilities · 26 Wages · 27a Other expenses · 30 Home office |
| **III · Cost of goods sold** | 36 Purchases · 37 Labor · 38 Materials & supplies · 39 Other costs |
| **Tracked, not deducted** | Capital purchase (for depreciation, ask your accountant) · Not deductible |

**Meals (24b)** are counted at 50% automatically. **Business-use %** applies on top.

## Vehicles

**Vehicles & Mileage** tab:

1. Add a vehicle, link it to the business, and set the date placed in service.
2. Choose a method:
   - **Standard mileage rate:** business miles × the IRS rate for the year, plus business parking and tolls.
   - **Actual expenses:** the vehicle's fuel, repairs, tires, insurance, registration, interest and so on, multiplied by the **business-use %** (business miles ÷ total miles). Lease payments go to line 20a.
3. **Log trips** (date, miles, business / commuting / personal, purpose), or enter yearly odometer totals.
4. Tag vehicle expenses: Tag Transactions ▸ **Vehicle**, or the transaction form's vehicle and expense type.

**IRS standard mileage rates** are editable in the mileage rates editor. Built-in values (cents per mile):

| Year | Rate |
|---|---|
| 2021 | 56 |
| 2022 | *enter yourself: the IRS used two rates that year (58.5¢ Jan–Jun, 62.5¢ Jul–Dec)* |
| 2023 | 65.5 |
| 2024 | 67 |
| 2025 | 70 |
| 2026 and later | *enter when the IRS publishes them* |

## Reports

- **Schedule C** tab: the selected business for a **tax year** or custom range, laid out by part and line.
  - Click a line to see the transactions behind it.
  - A banner lists business transactions that still need a line.
  - Includes a vehicle worksheet showing the method used and the amounts.
  - **Export CSV** gives the summary, the vehicle worksheet and the full transaction detail.
- **Profit & Loss** tab: income and expenses by category, with a monthly bar chart.
- **All Businesses** (sidebar, once you have two or more): every business side by side.

## Multiple businesses

Each business has its own accounts, tags, vehicles and Schedule C. A transaction counts toward one business at a time. Category-to-line mappings are shared, since a category such as *Office Supplies* means the same thing for every business. The line can still be overridden on any transaction.
