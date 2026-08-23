# Contributing to gobot

## Prerequisites
- Go 1.26.2+
- `golangci-lint` v2.11.4 (`go install github.com/golangci/golangci-lint/cmd/golangci-lint@v2.11.4`)
- `make` (optional, for using the Makefile)

## Building
Using the Makefile:
```bash
make build
```
Or directly via Go:
```bash
go build -mod=vendor -ldflags "-X main.version=v0.1.0-dev" -o bin/gobot ./cmd/gobot
```

## Testing
Using the Makefile:
```bash
make test
```
Or directly via Go:
```bash
go test -race -mod=readonly ./internal/... ./cmd/...
```

## Linting
Using the Makefile:
```bash
make lint
```
Or directly via `golangci-lint`:
```bash
golangci-lint run --modules-download-mode=readonly
```

## Coding Standards
- **Configuration**: `config.json` must be formatted with 4-space indentation and a UTF-8 BOM. Use `go run ./cmd/gobot config reformat` to fix formatting and `go run ./cmd/gobot config validate` to check for errors.
- **Line endings**: `.gitattributes` pins all text to LF (`* text=auto eol=lf`). Commit LF and let git handle the checkout; do not set `core.autocrlf=true` for this repo. This does not affect the `config.json` BOM above - `eol=lf` normalizes line endings, not byte-order marks. Two traps when auditing this on Windows: `git status` reports working-tree drift, not what the repo stores, so settle line-ending questions against the blob (`git cat-file blob HEAD:<path>`); and `sed -i` silently strips every CR from a CRLF file, so edit one with a byte-preserving read/replace/write instead.
- **Wrap all errors**: `fmt.Errorf("context: %w", err)` — never return naked errors from external calls.
- **Context usage**: Pass `context.Context` as the first parameter to every function that performs I/O.
- **No panics**: Avoid `panic()` in `internal/` packages; return errors instead.
- **Interface design**: Interfaces belong in the package that consumes them, not the package that implements them.
- **Testing patterns**: Use table-driven tests with `testify/assert` and subtests via `t.Run`.
- **Concurrency**: No global mutable state without a mutex and a documented reset path for tests.
- **Logging**: Use structured logging with `log/slog`. Maintain consistent keys such as `session_id` and `err`.
- **Extensibility**: Follow the Strategic Hook pattern (F-012) for custom logic extensions.

## Submitting Changes
- **Atomic Commits**: One logical change per PR.
- **CI Validation**: All CI checks (lint, test, doc-lint, coverage) must pass before review.
- **Commit Messages**: Use the imperative mood and present tense (e.g., `add`, `fix`, `refactor`).
- **Documentation**: Update relevant documentation in `docs/` if your change affects architecture or configuration.
