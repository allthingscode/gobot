//nolint:testpackage // intentionally uses unexported helpers from main package
package main

import (
	"testing"

	"github.com/spf13/cobra"
)

// TestBuildIntegrity ensures the root command can be initialized without panicking.
// This catches syntax errors, missing imports, and initialization logic errors
// in main.go and its sub-commands.
func TestBuildIntegrity(t *testing.T) {
	t.Parallel()
	defer func() {
		if r := recover(); r != nil {
			t.Errorf("Root command initialization panicked: %v", r)
		}
	}()

	// We don't execute it (to avoid starting the bot),
	// just ensure the command tree is buildable.
	root := &cobra.Command{
		Use: "gobot",
	}
	root.AddCommand(
		cmdVersion(),
		cmdInit(),
		cmdDoctor(),
		cmdRun(),
		cmdReauth(),
		cmdCheckpoints(),
		cmdResume(),
		cmdSimulate(),
		cmdCalendar(),
		cmdTasks(),
	)

	if root.Name() != "gobot" {
		t.Errorf("Expected root command name 'gobot', got %s", root.Name())
	}
}
