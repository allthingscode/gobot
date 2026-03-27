// gobot — Strategic Edition agent runtime (Go)
package main

import (
	"fmt"
	"os"

	"github.com/spf13/cobra"

	"github.com/allthingscode/gobot/internal/config"
	"github.com/allthingscode/gobot/internal/doctor"
)

const version = "0.1.0"

func main() {
	root := &cobra.Command{
		Use:   "gobot",
		Short: "Strategic Edition agent runtime",
		Long:  "gobot — the Go-native runtime for Nanobot Strategic Edition.",
	}

	root.AddCommand(
		cmdVersion(),
		cmdInit(),
		cmdDoctor(),
		cmdRun(),
	)

	if err := root.Execute(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

func cmdVersion() *cobra.Command {
	return &cobra.Command{
		Use:   "version",
		Short: "Print gobot version and Go runtime info",
		Run: func(cmd *cobra.Command, args []string) {
			fmt.Printf("gobot %s\n", version)
			fmt.Printf("go runtime: %s\n", goVersion())
		},
	}
}

func cmdInit() *cobra.Command {
	return &cobra.Command{
		Use:   "init",
		Short: "Create workspace directories on D: drive",
		RunE: func(cmd *cobra.Command, args []string) error {
			dirs := []string{
				`D:\Nanobot_Storage\workspace`,
				`D:\Nanobot_Storage\logs`,
				`D:\Nanobot_Storage\workspace\projects`,
				`D:\Nanobot_Storage\workspace\sessions`,
			}
			for _, d := range dirs {
				if err := os.MkdirAll(d, 0o755); err != nil {
					return fmt.Errorf("failed to create %s: %w", d, err)
				}
				fmt.Printf("  ok  %s\n", d)
			}
			fmt.Println("init complete.")
			return nil
		},
	}
}

func cmdDoctor() *cobra.Command {
	return &cobra.Command{
		Use:   "doctor",
		Short: "Run strategic health checks",
		RunE: func(cmd *cobra.Command, args []string) error {
			cfg, err := config.Load()
			if err != nil {
				return fmt.Errorf("config load failed: %w", err)
			}
			return doctor.Run(cfg)
		},
	}
}

func cmdRun() *cobra.Command {
	return &cobra.Command{
		Use:   "run",
		Short: "Run the strategic agent (Phase 4 — not yet implemented)",
		Run: func(cmd *cobra.Command, args []string) {
			fmt.Println("agent run: not yet implemented (Phase 4).")
			fmt.Println("Use the Python launcher in the nanobot project for now.")
		},
	}
}
