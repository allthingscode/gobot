package main

import (
	"strings"
	"testing"
)

func TestCmdRunWebAddrHelpDescribesSeparateSSEListener(t *testing.T) {
	t.Parallel()

	flag := cmdRun().Flags().Lookup("web-addr")
	if flag == nil {
		t.Fatal("web-addr flag is missing")
	}
	if !strings.Contains(flag.Usage, "separate SSE dashboard/log stream") {
		t.Fatalf("web-addr help = %q, want separate SSE listener semantics", flag.Usage)
	}
	if strings.Contains(flag.Usage, "management dashboard") {
		t.Fatalf("web-addr help = %q, must not call it the management dashboard", flag.Usage)
	}
}
