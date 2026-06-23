//nolint:testpackage // intentionally uses unexported buildRootCmd from main package
package main

import (
	"regexp"
	"testing"

	"github.com/spf13/cobra"
	"github.com/spf13/pflag"
)

// internalIDPattern matches Crucible-internal task identifiers (F-111, R-013, C-328).
var internalIDPattern = regexp.MustCompile(`[FRC]-\d+`)

// TestNoInternalTaskIDsInHelp walks the assembled cobra command tree and fails if any
// user-facing help/usage string leaks an internal task ID (C-328). Code comments are
// out of scope and not inspected here.
func TestNoInternalTaskIDsInHelp(t *testing.T) {
	t.Parallel()

	var walk func(cmd *cobra.Command)
	walk = func(cmd *cobra.Command) {
		path := cmd.CommandPath()
		check := func(field, value string) {
			if m := internalIDPattern.FindString(value); m != "" {
				t.Errorf("internal task ID %q leaked in %s %s: %q", m, path, field, value)
			}
		}
		check("Use", cmd.Use)
		check("Short", cmd.Short)
		check("Long", cmd.Long)
		check("Example", cmd.Example)
		for _, a := range cmd.Aliases {
			check("Alias", a)
		}
		cmd.Flags().VisitAll(func(f *pflag.Flag) {
			check("flag --"+f.Name+" usage", f.Usage)
		})
		for _, sub := range cmd.Commands() {
			walk(sub)
		}
	}

	walk(buildRootCmd())
}
