# Money File Format Notes

These notes cover what we learned reading Microsoft Money Plus Sunset Edition files. Money's format was never documented publicly, so this is offered for anyone else trying to rescue their data. Every rule here is implemented in [`MnyExport.java`](../tools/mny-export/src/MnyExport.java) and was checked against a real file with about 20 years of data.

## Container

- A `.mny` file is an **MSISAM 4.0** database, Microsoft's encrypted variant of the Jet (Access) format.
- [Jackcess](https://jackcess.sourceforge.io/) with **jackcess-encrypt** opens it via `CryptCodecProvider`, with the password if there is one (blank otherwise).
- Open a **copy**, read-only. Money is particular about its files.

## Key tables

| Table | Contents |
|---|---|
| `ACCT` | Accounts |
| `CAT` | Categories (a tree) |
| `PAY` | Payees |
| `TRN` | Transactions, including bill templates (see `frq`) |
| `TRN_SPLIT` | Split lines → parent transaction |
| `TRN_XFER` | Transfer pairs |
| `BILL` | Recurring bill series (versioned) |
| `XBAG` | Assorted extras, including register flags |

## ACCT

- `hacct`: ID. `szFull`: name. `fClosed`: closed.
- `at`: account type. 0 = bank, 1 = credit card, 5 = investment, 6 = loan. Other values exist for assets and liabilities.
- `amtOpen`: opening balance. `dtOpen`: open date.
- Last reconciled date and balance are stored per account. They're useful for verifying an import, but occasionally stale.

## CAT

- `hcat`, `hcatParent`, `szFull`, `nLevel`.
- The two root categories are named **`INCOME`** and **`EXPENSE`**. A category's kind is the root it descends from. Hide the roots when displaying names.

## TRN

| Column | Meaning |
|---|---|
| `htrn` | Transaction ID |
| `hacct` | Account |
| `dt` | Date |
| `amt` | Amount (negative = money out) |
| `lHpay` | Payee |
| `hcat` | Category |
| `mMemo` | Memo |
| `szId` | Number. The **first character is a type prefix**: `'0'` = check number, `'1'` = text code (ATM, DEBIT, EFT…). Strip it for display. |
| `cs` | Cleared status: 0 = uncleared, 1 = cleared, 2 = reconciled |
| `dtCleared` | When it was cleared |
| `frq` | **`-1` = real register entry.** Any other value is a scheduled-bill template, not a transaction. |
| `grftt` | Bit flags (below) |
| `hacctLink` | The other account, for transfers |
| `hbillHead`, `iinst` | The bill series and occurrence this entry was posted from |

`grftt` bits:

| Bit | Meaning |
|---|---|
| `0x2` | Transfer |
| `0x20` | Split parent |
| `0x100` | Void |
| `0x200000` | Bill template |

## TRN_SPLIT

- `htrn` → `htrnParent`, with `iSplit` giving the order.
- The **parent carries the full amount**, and the children carry the pieces, which add up to the parent. Use the parent for balances, so it's counted once.

## TRN_XFER

- `htrnFrom`, `htrnLink`: the two sides of a transfer. Each side is a full transaction in its own account with the opposite sign.

## BILL (recurring bills & deposits)

Bills are stored as **versioned series**:

- Every row has `hbillHead`, the series ID (the head row's own `hbill`), and `iinst`, the occurrence number from which that version applies.
- The **head row's `iinstNextUnpaid`** is the next occurrence that hasn't been posted.
- The version in effect is the row with the **largest `iinst` ≤ next unpaid**.
- The series is finished when `iinstNextUnpaid` reaches `cInstMax` (when that's ≥ 0), or the next date passes `dtMax`.
- The amount, payee, category and account come from the template `TRN` row the version points to (`frq != -1`).

`BILL.frq` (frequency) with `cFrqInst`:

| `frq` | Unit | `cFrqInst` |
|---|---|---|
| 0 | Once | — |
| 2 | Weekly | occurrences per week, e.g. 0.5 = every 2 weeks |
| 3 | Monthly | 2 = twice a month; 0.5 = every 2 months |
| 4 | Quarterly | — |
| 5 | Yearly | occurrences per year |

The next due date is the version's base date advanced by (next unpaid − version `iinst`) periods.

## XBAG (flags)

Register flags are **not** stored on `TRN`. They're `XBAG` rows with:

- `tbl = -4036` (the TRN table), `bt = 0`, `grf = 1`
- `lHobj` = the `htrn` of the flagged transaction
- `szMemo` = flag comment, `dtFollowup` = action date

Money keeps these rows after a transaction is reconciled, though its register no longer shows the flag. The importer applies the same rule.

## Dates

- Dates come back as local date-times. Treat them as calendar days.
- Any date in **year 2200 or later** is a "no date" placeholder (for example a bill with no end date).

## Export JSON (`macmoney-export` v1)

The converter writes:

```jsonc
{
  "format": "macmoney-export", "version": 1,
  "source": { "fileName": "…", "size": 0, "modified": "…", "sha256": "…" },
  "accounts":     [ { "moneyId", "name", "kind", "closed", "openingBalance", "openDate",
                      "lastReconciledDate", "lastReconciledBalance", "accountNumber", "comment", "isBusiness" } ],
  "categories":   [ { "moneyId", "parentId", "name", "level", "kind" } ],
  "payees":       [ { "moneyId", "name", "hidden" } ],
  "transactions": [ { "moneyId", "accountId", "date", "amount", "number", "payeeId", "categoryId", "memo",
                      "status", "dateCleared", "isVoid", "flagged", "flagNote", "flagDate",
                      "splitParentId", "splitOrder", "isSplitParent", "transferPeerId", "transferAccountId",
                      "billSeriesId", "billOccurrence" } ],
  "bills":        [ { "seriesId", "accountId", "payeeId", "categoryId", "amount", "memo", "number",
                      "transferAccountId", "frequency": { "unit", "every" }, "startDate", "nextDue",
                      "nextOccurrence", "maxOccurrences", "endDate", "finished", "splits" } ]
}
```

- Amounts are decimal strings with 2 places, to avoid floating-point rounding.
- Dates are `YYYY-MM-DD`.
- IDs are Money's own integer keys. They're stable across exports, which is what makes re-import work.
