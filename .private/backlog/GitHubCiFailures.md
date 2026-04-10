# GitHub CI Failures - RESOLVED

## [RESOLVED] GoLang CI - Lint
- **Issue**: `can't load config: unsupported version of the configuration: ""`
- **Fix**: 
  - Updated `.github/workflows/ci.yml` to use `golangci-lint-action` with version `v1.64.5`.
  - Added mandatory `run: version: 1` to `.golangci.yml`.
- **Verification**: `golangci-lint run` passes locally with `v1.64.8`.

## [RESOLVED] Linux - Go Test (TestRedirectCDrive)
- **Issue**: Path separator mismatch on Linux (`got ...\\...` want `.../...`).
- **Fix**: 
  - Updated `internal/shell/redirect.go` to normalize backslashes in the "inner" path to forward slashes before using `filepath.Join`.
  - Updated regex patterns to match both `\\` and `/` after the Windows volume colon.
  - Added new test case for forward-slash Windows paths in `internal/shell/shell_test.go`.
- **Verification**: `go test -v ./internal/shell/...` passes locally.
