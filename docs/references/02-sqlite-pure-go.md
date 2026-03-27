# Pure Go SQLite Best Practices

## 1. Why `modernc.org/sqlite`?
We strictly use `modernc.org/sqlite` instead of `github.com/mattn/go-sqlite3` to adhere to our **No CGO** mandate. 
*   **Benefit:** This ensures the `gobot` binary can be easily cross-compiled for any platform (especially Windows) without requiring a GCC toolchain or encountering C-binding edge cases.

## 2. Enabling WAL Mode
SQLite's default rollback journal is slow and locks the entire database on writes. Always enable Write-Ahead Logging (WAL) for significantly better concurrency, allowing multiple readers to access the DB simultaneously while a write is occurring.
*   **Implementation:** Run `PRAGMA journal_mode=WAL;` immediately after opening the connection.

```go
db, err := sql.Open("sqlite", dbPath)
if err != nil {
    return nil, err
}
if _, err := db.Exec("PRAGMA journal_mode=WAL"); err != nil {
    return nil, err
}
```

## 3. Connection Pooling Configuration
When using SQLite with Go's `database/sql`, you must configure the connection pool to avoid `database is locked` errors (SQLITE_BUSY), even in WAL mode. SQLite handles concurrency best with a single dedicated writer.
*   **Rule:** Always set `SetMaxOpenConns(1)`. This forces Go to serialize all database access through a single connection, preventing the application from fighting itself for database locks.

```go
db.SetMaxOpenConns(1)
// Optional: Prevent idle connections from closing unnecessarily
db.SetMaxIdleConns(1)
```

## 4. Handling Busy Timeouts
Even with `SetMaxOpenConns(1)`, if another process (like a DB browser or another instance) holds a lock, your query will fail instantly with `database is locked`.
*   **Fix:** Tell SQLite to wait and retry before giving up by setting `_pragma=busy_timeout(milliseconds)` in the connection string.

```go
// Wait up to 5 seconds for a lock before failing
dbPath := filepath.Join(dir, "checkpoints.db") + "?_pragma=busy_timeout(5000)"
db, err := sql.Open("sqlite", dbPath)
```

## 5. Parameterized Queries Only
Never concatenate strings to build SQL queries. Always use parameterized queries (`?`) to prevent SQL injection and allow SQLite to cache the query plan.

```go
// BAD
db.Exec(fmt.Sprintf("SELECT * FROM users WHERE id = %s", id))

// GOOD
db.QueryRow("SELECT * FROM users WHERE id = ?", id)
```
