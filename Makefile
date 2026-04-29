# Makefile for gobot Strategic Edition

VERSION  := $(shell git describe --tags --always --dirty 2>/dev/null || echo "v0.1.0-dev")
COMMIT   := $(shell git rev-parse --short HEAD 2>/dev/null || echo "unknown")
BUILT_AT := $(shell date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || echo "unknown")
LDFLAGS  := -X main.version=$(VERSION) -X main.commitHash=$(COMMIT) -X main.buildTime=$(BUILT_AT)

# Handle missing vendor directory
MOD_FLAG :=
ifeq ($(wildcard vendor/),)
    MOD_FLAG :=
    PREBUILD := go_mod_download
else
    MOD_FLAG := -mod=vendor
    PREBUILD :=
endif

.DEFAULT_GOAL := help

.PHONY: build test lint doc-lint cover clean help go_mod_download

go_mod_download:
	@echo "Vendor directory missing. Downloading modules..."
	go mod download

build: $(PREBUILD) ## Build the gobot binary
	@mkdir -p bin
	go build $(MOD_FLAG) -ldflags "$(LDFLAGS)" -o bin/gobot ./cmd/gobot

test: ## Run tests with race detection
	go test -race -mod=readonly ./internal/... ./cmd/...

bench: ## Run benchmarks
	@mkdir -p artifacts
	go test -mod=readonly -bench=. -benchmem -run='^$' ./internal/... ./cmd/... | tee artifacts/bench.txt

lint: ## Run golangci-lint
	golangci-lint run --modules-download-mode=readonly

doc-lint: ## Run project-specific documentation lint
	go run scripts/doc_lint.go

cover: ## Generate coverage report
	@mkdir -p artifacts
	go test -mod=readonly -coverprofile=artifacts/coverage.out ./internal/... ./cmd/...
	go tool cover -html=artifacts/coverage.out

clean: ## Remove build artifacts
	rm -rf bin artifacts *.out gobot gobot.exe coverage.out

help: ## Show this help
	@echo "Usage: make [target]"
	@echo ""
	@echo "Targets:"
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "  %-12s %s\n", $$1, $$2}'
