# Makefile for gobot Strategic Edition

VERSION  := $(shell git describe --tags --always --dirty 2>/dev/null || echo "v0.1.0-dev")
COMMIT   := $(shell git rev-parse --short HEAD 2>/dev/null || echo "unknown")
BUILT_AT := $(shell date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || echo "unknown")
LDFLAGS  := -X main.version=$(VERSION) -X main.commitHash=$(COMMIT) -X main.buildTime=$(BUILT_AT)

.DEFAULT_GOAL := help

.PHONY: build test lint doc-lint cover clean help

build: ## Build the gobot binary
	go build -mod=vendor -ldflags "$(LDFLAGS)" -o gobot ./cmd/gobot

test: ## Run tests with race detection
	go test -race -mod=readonly ./internal/... ./cmd/...

lint: ## Run golangci-lint
	golangci-lint run --modules-download-mode=readonly

doc-lint: ## Run project-specific documentation lint
	go run scripts/doc_lint.go

cover: ## Generate coverage report
	go test -mod=readonly -coverprofile=coverage.out ./internal/... ./cmd/...
	go tool cover -html=coverage.out

clean: ## Remove build artifacts
	rm -f gobot gobot.exe coverage.out

help: ## Show this help
	@echo "Usage: make [target]"
	@echo ""
	@echo "Targets:"
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "  %-12s %s\n", $$1, $$2}'
