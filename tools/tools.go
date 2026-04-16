//go:build tools

package tools

import (
	_ "golang.org/x/perf/cmd/benchstat"
	_ "golang.org/x/vuln/cmd/govulncheck"
	_ "gotest.tools/gotestsum"
	_ "mvdan.cc/gofumpt"
)
