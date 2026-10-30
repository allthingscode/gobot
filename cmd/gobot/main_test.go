//nolint:testpackage // main package tests share command helpers
package main

import (
	"os"
	"testing"

	"github.com/allthingscode/gobot/internal/testutil"
)

func TestMain(m *testing.M) {
	os.Exit(testutil.RunHermeticTests(m))
}
