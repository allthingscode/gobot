//nolint:testpackage // exercises unexported startup-time probe helpers
package doctor

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func writeStartupJSON(t *testing.T, root, body string) {
	t.Helper()
	ws := filepath.Join(root, "workspace")
	if err := os.MkdirAll(ws, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(ws, "startup.json"), []byte(body), 0o600); err != nil {
		t.Fatal(err)
	}
}

func TestCheckStartupTime_MissingMarkerIsOK(t *testing.T) {
	t.Parallel()
	r := checkStartupTime(cfgWithRoot(t.TempDir()))
	if !r.OK || r.Critical {
		t.Fatalf("missing startup marker = {OK:%v Critical:%v}, want advisory OK", r.OK, r.Critical)
	}
	if r.Detail != "not recorded yet" {
		t.Fatalf("Detail = %q, want %q", r.Detail, "not recorded yet")
	}
}

func TestCheckStartupTime_ValidMarker(t *testing.T) {
	t.Parallel()
	root := t.TempDir()
	readyAt := time.Date(2026, 7, 7, 12, 30, 0, 0, time.UTC)
	writeStartupJSON(t, root, `{"version":1,"ready_at":"`+readyAt.Format(time.RFC3339Nano)+`","duration_ms":1234}`)

	r := checkStartupTime(cfgWithRoot(root))
	if !r.OK {
		t.Fatalf("valid startup marker should be OK, got %+v", r)
	}
	if !strings.Contains(r.Detail, "1234 ms at 2026-07-07T12:30:00Z") {
		t.Fatalf("Detail = %q, want duration and timestamp", r.Detail)
	}
}

func TestCheckStartupTime_InvalidMarkerWarns(t *testing.T) {
	t.Parallel()
	root := t.TempDir()
	writeStartupJSON(t, root, "{not json")

	r := checkStartupTime(cfgWithRoot(root))
	if r.OK {
		t.Fatal("invalid startup marker must be advisory WARN (OK=false)")
	}
	if r.Critical {
		t.Fatal("invalid startup marker must remain non-critical")
	}
	if r.Remediation == "" {
		t.Fatal("invalid startup marker must carry a remediation")
	}
}

func TestGetResults_IncludesStartupTime(t *testing.T) {
	t.Parallel()
	results := GetResults(doctorTestCfg(t), nil)
	for i := range results {
		if results[i].Name == "startup time" {
			if results[i].Critical {
				t.Fatal("startup time result must be non-critical")
			}
			return
		}
	}
	t.Fatal("GetResults did not include a 'startup time' result")
}
