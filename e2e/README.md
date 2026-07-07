# Dashboard E2E (Playwright)

End-to-end browser tests for the GoBot dashboard (`internal/dashboard`).

Playwright boots a standalone dashboard instance via `harness/main.go` (built with
the `e2e` tag, so it stays out of `go build ./...`). The harness serves the embedded
UI plus an SSE log stream seeded with sample entries and a periodic `heartbeat`, so
tests run without the full gobot binary or any Telegram config.

## Setup

```powershell
cd e2e
npm install
npx playwright install   # browsers, only needed once per machine
```

## Run

```powershell
npm test            # headless
npm run test:headed # headed
npm run test:ui     # interactive UI mode
npm run report      # open last HTML report
```

The Go harness is launched automatically. To drive a manually started server
instead, run `go run -tags e2e ./harness` from this directory and Playwright will
reuse it (set `DASHBOARD_E2E_PORT` to change the port; default `8099`).
