# Contributing to gobot

First off, thanks for taking the time to contribute!

The following is a set of guidelines for contributing to gobot. These are mostly guidelines, not rules. Use your best judgment, and feel free to propose changes to this document in a pull request.

## Prerequisites

Before you begin, ensure you have the following installed:
- **Go 1.25+** (see `go.mod` for the exact version)
- **Linters**: `staticcheck` and `golangci-lint`
- **Platform**: Windows is required for DPAPI secrets (though core features support other platforms)

## Dev Setup

1. **Clone the repository:**
   ```bash
   git clone https://github.com/allthingscode/gobot.git
   cd gobot
   ```

2. **Build the project:**
   ```bash
   go build ./cmd/gobot
   ```

3. **Run the tests:**
   ```bash
   gotestsum --format testdox -- -mod=readonly ./internal/... ./cmd/...
   ```

## Hook Installation

We use a pre-commit hook to enforce code quality. Install it via:

```bash
cp scripts/hooks/pre-commit .git/hooks/pre-commit && chmod +x .git/hooks/pre-commit
```

## Code Standards

Gobot adheres to strict engineering mandates. All contributions must respect these rules:

- **Pure Go**: No CGO under any circumstances.
- **Wrapped Errors**: Never return bare errors. Always wrap them: `fmt.Errorf("context: %w", err)`.
- **Structured Logging**: Use `log/slog` for all logging.
- **Table-Driven Tests**: Write table-driven tests and aim for an 80%+ test coverage target.
- **No Panics**: Never use `panic()` in `internal/` packages. Handle and return errors gracefully.

## PR Process

A great Pull Request is one that:
- Fixes a single issue or adds a single feature (single concern per PR).
- Includes corresponding table-driven tests with adequate coverage.
- Passes all tests (`gotestsum`) and linting (`golangci-lint`).
- Does not break existing functionality or architectural mandates.

## Commit Style

Please follow [Conventional Commits](https://www.conventionalcommits.org/) for your commit messages. Use types like:
- `feat:` for new features
- `fix:` for bug fixes
- `chore:` for routine tasks, tooling, or dependencies
- `docs:` for documentation updates
- `refactor:` for code restructuring without behavior changes
