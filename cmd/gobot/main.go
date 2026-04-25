// gobot - Strategic Edition agent runtime (Go)
//go:generate go-winres make --in ../../versioninfo.json
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
		cmdClearCheckpoint(),
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
		fmt.Fprintf(os.Stderr, "Error: %v\n", err)
		os.Exit(1)
	}
}

func cmdVersion() *cobra.Command {
	return &cobra.Command{
		Use:   "version",
		Short: "Print version information",
		Run: func(cmd *cobra.Command, _ []string) {
			fmt.Fprintf(cmd.OutOrStdout(), "gobot %s (%s) built %s\n", version, commitHash, buildTime)
			fmt.Fprintf(cmd.OutOrStdout(), "runtime: %s/%s (%s)\n", runtime.GOOS, runtime.GOARCH, runtime.Version())
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
		if err := os.Setenv("GOBOT_STORAGE", root); err != nil {
			return fmt.Errorf("set env: %w", err)
		}
	}
	cfg, err := config.Load()
	if err != nil {
		return fmt.Errorf("load config: %w", err)
	}
	if err := os.MkdirAll(cfg.StorageRoot(), 0o755); err != nil {
		return fmt.Errorf("mkdir storage root: %w", err)
	}
	dirs := []string{"sessions", "secrets", "memory", "logs"}
	for _, d := range dirs {
		if err := os.MkdirAll(cfg.WorkspacePath("", d), 0o755); err != nil {
			return fmt.Errorf("mkdir %s: %w", d, err)
		}
	}

	configPath := config.DefaultConfigPath()
	if _, err := os.Stat(configPath); os.IsNotExist(err) {
		if err := cfg.Save(configPath); err != nil {
			return fmt.Errorf("save default config: %w", err)
		}
		fmt.Printf("Created default config file at %s\n", configPath)
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
				return fmt.Errorf("load config: %w", err)
			}
			return doctor.Run(cfg, app.LiveProbes())
		},
	}
}

func cmdRun() *cobra.Command {
	var webAddr string
	cmd := &cobra.Command{
		Use:   "run",
		Short: "Start the strategic agent (Gateway + Telegram)",
		RunE: func(cmd *cobra.Command, _ []string) error {
			cfg, err := config.Load()
			if err != nil {
				return fmt.Errorf("load config: %w", err)
			}
			if webAddr != "" {
				cfg.Gateway.WebAddr = webAddr
			}
			return app.RunAgent(cmd.Context(), cfg)
		},
	}
	cmd.Flags().StringVar(&webAddr, "web-addr", "", "Address for the F-111 web dashboard (e.g. 127.0.0.1:7331)")
	return cmd
}
