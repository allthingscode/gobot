// gobot - Strategic Edition agent runtime (Go)
package main

import (
	"fmt"
	"os"
	"runtime"

	"github.com/spf13/cobra"

	"github.com/allthingscode/gobot/internal/app"
	"github.com/allthingscode/gobot/internal/config"
	"github.com/allthingscode/gobot/internal/doctor"
)

//nolint:gochecknoglobals // Build-time injection via -ldflags, not mutable at runtime
var (
	version    = "dev"     // overridden at build time via -ldflags
	commitHash = "unknown" // overridden at build time via -ldflags
	buildTime  = "unknown" // overridden at build time via -ldflags
)

func main() {
	root := &cobra.Command{
		Use:   "gobot",
		Short: "Strategic Edition agent runtime",
		Long:  "gobot - the Go-native runtime for gobot Strategic Edition.",
	}
	root.SilenceErrors = true

	root.AddCommand(
		cmdVersion(),
		cmdInit(),
		cmdDoctor(),
		cmdRun(),
		cmdSimulate(),
		cmdRewind(),
		cmdMemory(),
		cmdFactory(),
		cmdLogs(),
		cmdConfig(),
		cmdCheckpoints(),
		cmdResume(),
		cmdAuthorize(),
		cmdReauth(),
		cmdSecrets(),
		cmdEmail(),
		cmdCalendar(),
		cmdTasks(),
		cmdState(),
	)

	if err := root.Execute(); err != nil {
		if !root.SilenceErrors {
			fmt.Fprintf(os.Stderr, "Error: %v\n", err)
		}
		os.Exit(1)
	}
}

func cmdVersion() *cobra.Command {
	return &cobra.Command{
		Use:   "version",
		Short: "Print version information",
		Run: func(_ *cobra.Command, _ []string) {
			fmt.Printf("gobot %s (%s) built %s\n", version, commitHash, buildTime)
			fmt.Printf("runtime: %s/%s (%s)\n", runtime.GOOS, runtime.GOARCH, runtime.Version())
		},
	}
}

func cmdInit() *cobra.Command {
	var rootFlag string
	cmd := &cobra.Command{
		Use:   "init",
		Short: "Create gobot workspace directories under the configured storage root",
		RunE: func(_ *cobra.Command, _ []string) error {
			return runInit(rootFlag)
		},
	}
	cmd.Flags().StringVar(&rootFlag, "root", "", "Custom storage root directory")
	return cmd
}

func runInit(root string) error {
	if root != "" {
		if err := os.Setenv("GOBOT_STORAGE_ROOT", root); err != nil {
			return err
		}
	}
	cfg, err := config.Load()
	if err != nil {
		return err
	}
	if err := os.MkdirAll(cfg.StorageRoot(), 0o755); err != nil {
		return err
	}
	dirs := []string{"sessions", "secrets", "memory", "logs"}
	for _, d := range dirs {
		if err := os.MkdirAll(cfg.WorkspacePath("", d), 0o755); err != nil {
			return err
		}
	}
	fmt.Printf("Initialized gobot workspace at %s\n", cfg.StorageRoot())
	return nil
}

func cmdDoctor() *cobra.Command {
	return &cobra.Command{
		Use:   "doctor",
		Short: "Run system health checks and diagnostics",
		RunE: func(_ *cobra.Command, _ []string) error {
			cfg, err := config.Load()
			if err != nil {
				return err
			}
			return doctor.Run(cfg, app.LiveProbes())
		},
	}
}

func cmdRun() *cobra.Command {
	return &cobra.Command{
		Use:   "run",
		Short: "Start the strategic agent (Gateway + Telegram)",
		RunE: func(cmd *cobra.Command, _ []string) error {
			cfg, err := config.Load()
			if err != nil {
				return err
			}
			return app.RunAgent(cmd.Context(), cfg)
		},
	}
}
