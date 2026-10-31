-- Frozen v11 domain tables from b203912. Do not regenerate from current models.
CREATE TABLE IF NOT EXISTS note (
        id INTEGER PRIMARY KEY,
        sync_id TEXT,
        title TEXT,
        color TEXT,
        content TEXT,
        reminder TEXT,
        remote_id TEXT,
        labels TEXT DEFAULT "",
        locked INTEGER DEFAULT 0,
        pinned INTEGER DEFAULT 0,
        trashed INTEGER DEFAULT 0,
        plain_text TEXT DEFAULT "",
        archived INTEGER DEFAULT 0,
        read_only INTEGER DEFAULT 0,
        completed INTEGER DEFAULT 0,
        attachments TEXT DEFAULT '[]',
        created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
        updated_at DATETIME DEFAULT CURRENT_TIMESTAMP
      );
CREATE TABLE IF NOT EXISTS label (
        id INTEGER PRIMARY KEY,
        sync_id TEXT,
        name TEXT NOT NULL,
        is_system INTEGER DEFAULT 0,
        created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
        updated_at DATETIME DEFAULT CURRENT_TIMESTAMP
      );
CREATE TABLE IF NOT EXISTS note_sort_context (
        context_key TEXT PRIMARY KEY,
        sort_mode TEXT NOT NULL,
        revision TEXT NOT NULL,
        base_revision TEXT,
        updated_at TEXT NOT NULL,
        dirty INTEGER NOT NULL DEFAULT 0,
        hydrated INTEGER NOT NULL DEFAULT 0
      );
