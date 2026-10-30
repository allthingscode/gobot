//nolint:testpackage // isolates storage fallbacks used by dashboard handlers
package dash

import (
	"os"
	"testing"

	"github.com/allthingscode/gobot/internal/testutil"
)

func TestMain(m *testing.M) {
	os.Exit(testutil.RunHermeticTests(m))
}
