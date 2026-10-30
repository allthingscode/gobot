//nolint:testpackage // establishes isolation for internal and external app tests
package app

import (
	"os"
	"testing"

	"github.com/allthingscode/gobot/internal/testutil"
)

func TestMain(m *testing.M) {
	os.Exit(testutil.RunHermeticTests(m))
}
