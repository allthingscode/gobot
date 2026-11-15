//nolint:testpackage // exercises the real MCP helper subprocess and TestMain
package app

import (
	"os"
	"os/exec"
	"testing"
)

func TestMCPServerHelperProcess_DoesNotLeakTempRoots(t *testing.T) {
	t.Parallel()
	tmp := t.TempDir()
	cmd := exec.CommandContext(t.Context(), os.Args[0], "-test.run=^TestMCPServerHelperProcess$") //nolint:gosec // runs only this test binary with a fixed selector
	cmd.Env = append(os.Environ(), "GO_WANT_MCP_HELPER=1", "GO_MCP_BEHAVIOR=", "TMP="+tmp, "TEMP="+tmp, "TMPDIR="+tmp)
	// EOF makes the actual protocol helper call os.Exit(0).
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("MCP helper: %v\n%s", err, out)
	}
	entries, err := os.ReadDir(tmp)
	if err != nil {
		t.Fatal(err)
	}
	if len(entries) != 0 {
		t.Fatalf("MCP helper leaked %d temporary roots", len(entries))
	}
}
