//nolint:testpackage // establishes isolation before parallel secure-store tests
package google

import (
	"os"
	"testing"

	"github.com/allthingscode/gobot/internal/testutil"
)

func TestMain(m *testing.M) {
	os.Exit(testutil.RunHermeticTests(m))
}
