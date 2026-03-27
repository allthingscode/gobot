# Go Architecture & Design

## 1. Standard Project Layout
We follow the idiomatic Go project layout:
*   `cmd/gobot/`: Contains the `main.go` and CLI wiring. Minimum logic here.
*   `internal/`: Contains the core business logic of the application. Code here cannot be imported by external projects. This is where 90% of our code lives (`internal/config`, `internal/context`, `internal/provider`).
*   `pkg/`: (Optional) Library code that is safe and intended for other projects to import. Use sparingly.

## 2. Accept Interfaces, Return Structs
This is a fundamental Go proverb.
*   **Functions should accept interfaces:** If your function only needs to read data, accept an `io.Reader`, not an `*os.File`. This makes the function infinitely easier to test (you can pass it a `strings.Reader` in tests).
*   **Functions should return concrete structs:** Returning an interface limits what the caller can do and obscures the actual type being returned.

```go
// Good
func ProcessData(r io.Reader) (*Result, error) { ... }

// Bad
func ProcessData(f *os.File) (ResultInterface, error) { ... }
```

## 3. Error Wrapping
Always add context to errors as they bubble up the stack using `fmt.Errorf` with the `%w` verb. This creates an error chain that can be inspected with `errors.Is` or `errors.As`.

```go
// BAD: destroys the original error type and stack trace
if err != nil {
    return fmt.Errorf("database query failed: %v", err)
}

// GOOD: wraps the error, preserving the original error for inspection
if err != nil {
    return fmt.Errorf("failed to fetch user %s: %w", userID, err)
}
```

## 4. Package Naming Conventions
*   **Short and lowercase:** `config`, `audit`, `provider`.
*   **No underscores or mixedCaps:** Avoid `user_service` or `ConfigManager`.
*   **Descriptive:** The package name is part of the caller's context. A function `Load()` inside the `config` package is called as `config.Load()`. Don't name it `config.LoadConfig()`.
*   **Avoid "util", "common", "helpers":** These become dumping grounds. Group code by *what it does*, not *what it is*.

## 5. Minimize Global State
Avoid package-level variables (`var Db *sql.DB`) and `init()` functions that perform setup logic.
*   **Why:** Global state makes unit testing difficult and hides dependencies.
*   **Fix:** Pass dependencies explicitly via structs (Dependency Injection).

```go
// Good: Dependencies are explicit
type Service struct {
    db *sql.DB
}

func NewService(db *sql.DB) *Service {
    return &Service{db: db}
}
```
