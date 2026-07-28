# Verification

gobot uses a two-lane verification model so local Windows development can stay
pure Go while CI still exercises the Go race detector.

## CI Race Lane

GitHub Actions is the authoritative race-detector lane. The CI test job must
continue to run:

```bash
go test -race -mod=readonly ./internal/... ./cmd/...
```

That job runs on GitHub-hosted runners with the CGO and compiler support needed
by the Go race detector. It uses the same scoped first-party package set as
local verification and the pre-push hook. A race-test failure in CI is a real
verification failure and should be fixed before deployment.

## Local No-CGO Lane

Windows agents and local shells that run with `CGO_ENABLED=0` are not expected
to pass `go test -race`, because the Go race detector requires CGO support.
Their supported local path is the scoped non-race verification set:

```powershell
powershell.exe -ExecutionPolicy Bypass -File .crucible/powershell/run-isolated-checks.ps1 -TaskId C-374 -Mode quick -ProjectRoot "<repo>"
```

For ad-hoc checks, use the same scoped package set:

```powershell
go test -mod=readonly ./internal/... ./cmd/...
go vet -mod=readonly ./internal/... ./cmd/...
```

The pre-push hook follows the same policy. It attempts the scoped race test
first; if the race detector reports that CGO or a C compiler is unavailable, it
warns and runs the scoped non-race tests instead. Ordinary test failures still
fail the hook.

## Running Race Tests Locally

Developers who need local race coverage should run the scoped race test from a
CGO-capable Go environment, such as WSL on Windows:

```bash
wsl -e go test -race -mod=readonly ./internal/... ./cmd/...
```
