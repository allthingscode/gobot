//nolint:testpackage // exercises unexported checkMemory and cfgWithRoot helper
package doctor

import (
	"regexp"
	"testing"
)

var memoryDetailRe = regexp.MustCompile(`^heap [0-9.]+ MiB, sys [0-9.]+ MiB$`)

func TestCheckMemory_Informational(t *testing.T) {
	t.Parallel()
	r := checkMemory()

	if r.Name != "memory" {
		t.Errorf("Name = %q, want %q", r.Name, "memory")
	}
	if !r.OK {
		t.Error("memory check should always be OK (informational)")
	}
	if r.Critical {
		t.Error("memory check must not be critical")
	}
	if !memoryDetailRe.MatchString(r.Detail) {
		t.Errorf("Detail = %q, want match %q", r.Detail, memoryDetailRe.String())
	}
}

func TestGetResults_IncludesMemory(t *testing.T) {
	t.Parallel()
	results := GetResults(cfgWithRoot(t.TempDir()), nil)

	var found *Result
	for i := range results {
		if results[i].Name == "memory" {
			found = &results[i]
			break
		}
	}
	if found == nil {
		t.Fatal("GetResults did not include a 'memory' result")
	}
	if !found.OK || found.Critical {
		t.Errorf("memory result = {OK:%v Critical:%v}, want {OK:true Critical:false}", found.OK, found.Critical)
	}
}
