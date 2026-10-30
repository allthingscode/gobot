//nolint:testpackage // main package tests share command helpers
package main

import (
	"os"
	"testing"

	agentctx "github.com/allthingscode/gobot/internal/context"
	"github.com/allthingscode/gobot/internal/testutil"
)

func TestMain(m *testing.M) {
	os.Exit(testutil.RunHermeticTests(m, agentctx.ResetCheckpointManagerInstancesForTest))
}
