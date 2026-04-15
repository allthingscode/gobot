#!/usr/bin/env bash
# scripts/ci_check.sh
# Mirrors GitHub CI. Run before any push or Reviewer approval.
# Exit code: 0 = all checks pass, non-zero = at least one failed.

set -euo pipefail

# Check for golangci-lint prerequisite
if ! command -v golangci-lint &> /dev/null; then
    echo "Error: golangci-lint is not installed."
    echo "Please install it by running: go install github.com/golangci/golangci-lint/cmd/golangci-lint@v2.11.4"
    exit 1
fi

# govulncheck is omitted: runs in CI but is slow and not essential for pre-push

echo "==> [1/5] go vet"
go vet -mod=readonly ./internal/... ./cmd/...

echo "==> [2/5] golangci-lint"
golangci-lint run --modules-download-mode=readonly ./internal/... ./cmd/...

echo "==> [3/5] go test"
go test -mod=readonly ./internal/... ./cmd/...

echo "==> [4/4] doc-lint"
go run scripts/doc_lint.go

echo ""
echo "All CI checks passed."
