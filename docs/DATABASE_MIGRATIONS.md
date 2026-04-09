# Database Migrations

## Overview

The app uses SQLite via `sqflite`. The database file is stored at a platform-specific path:

| Platform    | Path                                                                  |
| ----------- | --------------------------------------------------------------------- |
| Windows     | `%APPDATA%\Foxbiz Software Pvt. Ltd\Better Keep Notes\better_keep.db` |
| Android/iOS | App-private storage (cleared on uninstall)                            |

The current schema version is defined in `lib/config.dart` as `databaseVersion`.

---

## Why Uninstall + Reinstall Does Not Fix Database Errors on Windows

On Windows, uninstalling the app does **not** delete the `%APPDATA%` folder. Windows preserves user data there intentionally. So the database file survives the uninstall and is picked up again immediately on the next launch — triggering the same crash.

Users would need to manually delete the database file or the entire app data folder before reinstalling for a clean slate:

```
%APPDATA%\Foxbiz Software Pvt. Ltd\Better Keep Notes\
```

This is not something users would know to do, so migration bugs must be fixed in code rather than relying on reinstall as a recovery path.

---

## Guidelines for Future Migrations

1. **Always guard `ALTER TABLE ADD COLUMN` with a column existence check** using `PRAGMA table_info(<table>)`. Never assume the column is absent just because the version number says it should be.
2. **Never rely on uninstall to reset state on desktop platforms.** AppData is preserved on Windows and macOS across uninstalls.
3. **Test migrations from every prior version**, not just the immediately previous one.
