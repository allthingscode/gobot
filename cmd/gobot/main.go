// gobot - Strategic Edition agent runtime (Go)
//
//go:generate go-winres make --in ../../versioninfo.json
package main

import (
	"fmt"
	"io"
	"os"
	"runtime"

	"github.com/spf13/cobra"

	"github.com/allthingscode/gobot/internal/app"
	"github.com/allthingscode/gobot/internal/config"
	"github.com/allthingscode/gobot/internal/doctor"
	"github.com/allthingscode/gobot/internal/secrets"
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
		RunE: func(cmd *cobra.Command, _ []string) error {
			return runInit(cmd.OutOrStdout(), rootFlag)
		},
	}
	cmd.Flags().StringVar(&rootFlag, "root", "", "Custom storage root directory")
	return cmd
}

func runInit(out io.Writer, root string) error {
	if root != "" {
		if err := os.Setenv("GOBOT_STORAGE", root); err != nil {
			return fmt.Errorf("set env: %w", err)
		}
	}
	cfg, err := config.Load()
	if err != nil {
		return fmt.Errorf("load config: %w", err)
	}
	if err := ensureWorkspace(out, cfg); err != nil {
		return err
	}

	fmt.Fprintf(out, "Initialized gobot workspace at %s\n", cfg.StorageRoot())
	printEncryptionKeyBackupWarning(out)
	return nil
}

// ensureWorkspace creates the required workspace directories if they are missing.
func ensureWorkspace(out io.Writer, cfg *config.Config) error {
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
	if _, err := os.Stat(configPath); err == nil {
		fmt.Fprintf(out, "Config file already exists at %s\n", configPath)
	} else if os.IsNotExist(err) {
		if err := cfg.Save(configPath); err != nil {
			return fmt.Errorf("save default config: %w", err)
		}
		fmt.Fprintf(out, "Created default config file at %s\n", configPath)
	}

	return nil
}

// printEncryptionKeyBackupWarning informs Linux/macOS users that the
// per-machine encryption key file is the root of trust for the secrets vault
// and must be backed up separately from the data directory. On Windows the
// secrets package uses DPAPI (no key file), so this helper is a no-op.
func printEncryptionKeyBackupWarning(out io.Writer) {
	keyPath := secrets.KeyFilePath()
	if keyPath == "" {
		return
	}
	fmt.Fprintln(out, "")
	fmt.Fprintln(out, "IMPORTANT: encryption key backup")
	fmt.Fprintln(out, "  Secrets are encrypted with a 32-byte AES-256 key stored at:")
	fmt.Fprintf(out, "    %s\n", keyPath)
	fmt.Fprintln(out, "  This file is the ROOT OF TRUST for your encrypted vault.")
	fmt.Fprintln(out, "  If it is lost, every stored secret becomes PERMANENTLY UNRECOVERABLE.")
	fmt.Fprintln(out, "  Back up this file separately from your data directory (e.g. password manager).")
	fmt.Fprintln(out, "  Override the location with the GOBOT_ENCRYPTION_KEY_FILE environment variable.")
	fmt.Fprintln(out, "  See docs/security.md for the full backup & restore procedure.")
}

// isWorkspaceIncomplete returns true if any of the required workspace directories are missing.
func isWorkspaceIncomplete(cfg *config.Config) bool {
	dirs := []string{"sessions", "secrets", "memory", "logs"}
	for _, d := range dirs {
		if _, err := os.Stat(cfg.WorkspacePath("", d)); os.IsNotExist(err) {
			return true
		}
	}
	return false
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

			if isWorkspaceIncomplete(cfg) {
				fmt.Fprintf(cmd.OutOrStdout(), "Workspace missing or incomplete at %s. Initializing...\n", cfg.StorageRoot())
				if err := ensureWorkspace(cmd.OutOrStdout(), cfg); err != nil {
					return fmt.Errorf("auto-init: %w", err)
				}
			}

			return app.RunAgent(cmd.Context(), cfg)
		},
	}
	cmd.Flags().StringVar(&webAddr, "web-addr", "", "Address for the F-111 web dashboard (e.g. 127.0.0.1:7331)")
	return cmd
}
