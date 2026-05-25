function Get-LanguagePresets {
    return @{
        go = @{
            quick = @(
                @{ name = "test"; command = "go test ./..." }
            )
            full = @(
                @{ name = "vet"; command = "go vet ./..." }
                @{ name = "lint"; command = "golangci-lint run ./..." }
                @{ name = "test"; command = "go test ./..." }
            )
        }
        node = @{
            quick = @(
                @{ name = "test"; command = "npm test" }
            )
            full = @(
                @{ name = "lint"; command = "npm run lint" }
                @{ name = "typecheck"; command = "npx tsc --noEmit" }
                @{ name = "test"; command = "npm test" }
            )
        }
        python = @{
            quick = @(
                @{ name = "test"; command = "pytest" }
            )
            full = @(
                @{ name = "lint"; command = "ruff check ." }
                @{ name = "typecheck"; command = "mypy ." }
                @{ name = "test"; command = "pytest" }
            )
        }
        rust = @{
            quick = @(
                @{ name = "test"; command = "cargo test" }
            )
            full = @(
                @{ name = "fmt"; command = "cargo fmt --check" }
                @{ name = "clippy"; command = "cargo clippy --all-targets" }
                @{ name = "test"; command = "cargo test" }
            )
        }
    }
}
