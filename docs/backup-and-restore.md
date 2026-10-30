# Backup & Restore

MacMoney keeps **point-in-time copies** of your data, so you can roll back to any moment, much like Money's "back up on exit".

## What a backup is

- A single, self-contained file: `MacMoney 2026-10-29 213900 (Automatic).macmoneybackup`.
- It's a complete SQLite copy of your data file, made with SQLite's online backup API, so it's consistent even while the app is open.
- **Every backup is checked** right after it's written, with SQLite's `PRAGMA integrity_check` plus a check that it really is a MacMoney file. A copy that fails is deleted and you're told.
- The name records when and why it was made: *Manual*, *Automatic*, *Before import* or *Before restore*.

## Encryption

**MacMoney ▸ Settings ▸ Backup ▸ Encryption.** Turn on **Encrypt backups with a password** and choose a password. It must be at least 8 characters; a passphrase of a few words is best.

- **The backup password is its own password.** It is *not* your Mac login password. On this Mac it's kept in your login keychain, so automatic backups never ask for it. macOS may ask once whether MacMoney may use it; choose **Always Allow**.
- **Write it down in your password manager.** If it's lost, encrypted backups can't be opened by anyone, including us. There's no back door.
- **Changing the password** affects new backups only. Older backups still need the password that was in effect when they were made.
- **Encrypt Existing Backups** converts the unencrypted backups already in your backup folder, in place.
- Encrypted backups show a 🔒 in **File ▸ Backups…**.

How it works:

- AES-256-GCM, with the key derived from your password using PBKDF2-HMAC-SHA256 (600,000 rounds, random salt per file).
- The data is encrypted in 1 MB chunks. Each chunk authenticates the file header, its own position and whether it's the last one. A changed byte, a reordered chunk, a cut-off file or an edited header is rejected instead of restored.
- The unencrypted snapshot exists only briefly in a private temp folder. After encrypting, MacMoney decrypts the result again and checks it before deleting the temp copy.
- Backup files are readable only by your user account (permissions `0600`).

## Moving to a new Mac

1. Install MacMoney on the new Mac and open it. With no data yet, it shows a **Welcome** screen.
2. Click **Restore from Backup** and choose your `.macmoneybackup`, from iCloud Drive ▸ MacMoney Backups, a USB drive or anywhere else.
3. If the backup is encrypted, MacMoney asks for its **backup password**: the one set in MacMoney when that backup was made, not the new Mac's login password. Leave **Remember this password on this Mac** ticked to keep backups encrypted there too.
4. MacMoney decrypts and checks the file, relaunches, and your data is back.

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

1. **File ▸ Backups…** (⇧⌘B), select a backup, then **Restore…**, or double-click it. Or use **Restore From File…** for a backup stored elsewhere.
2. Confirm, entering the backup password if MacMoney asks. MacMoney checks the file, **quits, swaps the data, and reopens**.
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
- Encryption: [`BackupCrypto.swift`](../App/MacMoney/Support/BackupCrypto.swift), including the file layout and the keychain storage.
- Settings are stored in user defaults under `backup.*`.
- An unencrypted backup is an ordinary SQLite database you can inspect with `sqlite3`. An encrypted one starts with the bytes `MMBK`, and only MacMoney's restore (or the documented format) can open it.
