# Backup & Restore

MacMoney keeps **point-in-time copies** of your data, so you can roll back to any moment, much like Money's "back up on exit".

## What a backup is

- A single, self-contained file: `MacMoney 2026-10-29 213900 (Automatic).macmoneybackup`.
- It's a complete SQLite copy of your data file, made with SQLite's online backup API, so it's consistent even while the app is open.
- **Every backup is checked** right after it's written, with SQLite's `PRAGMA integrity_check` plus a check that it really is a MacMoney file. A copy that fails is deleted and you're told.
- The name records when and why it was made: *Manual*, *Automatic*, *Before import* or *Before restore*.

## Automatic backups

**MacMoney ▸ Settings ▸ Backup:**

| Setting | Default | Notes |
|---|---|---|
| Back up automatically when MacMoney quits | On | |
| How often | Every time MacMoney quits | Or daily, weekly or monthly. The backup still happens at quit, but only once that much time has passed since the last automatic one. |
| Keep the *N* most recent | 10 | Applies to automatic, before-import and before-restore backups together. **Manual backups are never deleted automatically.** |
| Location | `~/Library/Application Support/MacMoney/Backups` | **Choose…** any folder, **Use iCloud Drive** (`iCloud Drive/MacMoney Backups`) for an off-Mac copy, or **Use Default**. |

A backup is also taken automatically:

- **before every Money import** (*Before import*);
- **before every restore** (*Before restore*), so a restore can be undone.

Backups are small, a few MB even with decades of data, so keeping many costs little.

## Manual backups

**File ▸ Backups…** (⇧⌘B):

- **Back Up Now:** saves a backup to the backup folder.
- **Back Up To…:** saves one to any folder, such as an external drive or a USB stick.
- **Show in Finder:** opens the backup folder.
- Right-click a backup for **Restore…**, **Show in Finder** or **Delete…** (moves it to the Trash).

## Restoring

1. **File ▸ Backups…**, select a backup, then **Restore…**. Or use **Restore From File…** for a backup stored elsewhere.
2. Confirm. MacMoney checks the file, **quits, swaps the data, and reopens**.
3. When it reopens you'll see a message confirming the restore. Your previous data was saved as a *Before restore* backup.

Why the restart: the data file can't be safely replaced while it's open, so the swap happens at the next launch, before the data file is opened. If the backup turns out to be unreadable, nothing is changed and you're told why.

## Check Data File

**File ▸ Check Data File…** is MacMoney's version of Money's repair tool. It **reports problems and never changes anything**:

| Check | Severity |
|---|---|
| SQLite integrity check of the data file | Problem: restore a backup |
| A Money transaction imported more than once | Problem: balances overstated |
| A transfer whose other side is missing | Warning |
| A transfer pair with different amounts | Warning |
| A split whose lines don't add up to the total | Warning |
| A transaction not in any account | Warning |
| An active bill with no account | Warning |
| A transaction dated more than 5 years ahead | Info: probably a typo |

Each finding shows up to five examples (date, account, payee, amount).

## Rollback plan

1. Leave automatic backups on and keep at least 10.
2. Point the backup folder at iCloud Drive, or make an occasional **Back Up To…** to an external drive, so a copy exists off the Mac.
3. Before anything big (a large import, bulk tagging), use **Back Up Now**. Manual backups are kept until you delete them.
4. If anything ever looks wrong, run **Check Data File** first, then restore the most recent good backup.

## Under the hood

- Code: [`App/MacMoney/Support/Backup.swift`](../App/MacMoney/Support/Backup.swift) and [`DataCheck.swift`](../App/MacMoney/Support/DataCheck.swift).
- Settings are stored in user defaults under `backup.*`.
- A backup is an ordinary SQLite database. You can inspect it with `sqlite3`, or open it in MacMoney by restoring it.
