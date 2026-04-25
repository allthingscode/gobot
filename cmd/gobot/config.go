package main

import (
	"fmt"
	"os"

	"github.com/allthingscode/gobot/internal/config"
	"github.com/spf13/cobra"
)

// exitCodeError is a custom error type that carries an exit code.
type exitCodeError struct {
	code int
	err  error
}

func (e *exitCodeError) Error() string {
	if e.err != nil {
		return e.err.Error()
	}
	return fmt.Sprintf("exit code %d", e.code)
}

func cmdConfig() *cobra.Command {
	cmd := &cobra.Command{
		Use:   "config",
		Short: "Configuration management commands",
		Long:  "Manage and validate gobot configuration.",
	}

	cmd.AddCommand(
		cmdConfigValidate(),
		cmdConfigReformat(),
	)

	return cmd
}

func cmdConfigReformat() *cobra.Command {
	var checkOnly bool
	cmd := &cobra.Command{
		Use:   "reformat [path]",
		Short: "Reformat config.json with standard 4-space indentation",
		Long:  "Reformat the configuration file. If no path is provided, the default ~/.gobot/config.json is used.",
		Args:  cobra.MaximumNArgs(1),
		RunE: func(_ *cobra.Command, args []string) error {
			path := config.DefaultConfigPath()
			if len(args) > 0 {
				path = args[0]
			}

			cfg, err := config.LoadFrom(path)
			if err != nil {
				return fmt.Errorf("load config: %w", err)
			}

			if checkOnly {
				return runFormatCheck(path, cfg)
			}

			if err := cfg.Save(path); err != nil {
				return fmt.Errorf("save config: %w", err)
			}
			fmt.Printf("Successfully reformatted %s\n", path)
			return nil
		},
	}
	cmd.Flags().BoolVar(&checkOnly, "check", false, "Only check if the config is correctly formatted without rewriting it")
	return cmd
}

func runFormatCheck(path string, cfg *config.Config) error {
	currentData, err := os.ReadFile(path)
	if err != nil {
		if os.IsNotExist(err) {
			return fmt.Errorf("config file %s does not exist", path)
		}
		return fmt.Errorf("read current config: %w", err)
	}
	formattedData, err := cfg.Marshal()
	if err != nil {
		return fmt.Errorf("marshal config: %w", err)
	}
	if string(currentData) != string(formattedData) {
		return fmt.Errorf("config %s is not correctly formatted; run 'gobot config reformat' to fix", path)
	}
	fmt.Printf("Config %s is correctly formatted\n", path)
	return nil
}

func cmdConfigValidate() *cobra.Command {
	cmd := &cobra.Command{
		Use:   "validate [path]",
		Short: "Validate configuration and exit with appropriate code",
		Long: `Validate the configuration file and report any errors.
If no path is provided, the default ~/.gobot/config.json is used.

Returns exit code:
  0 - Configuration is valid
  1 - Configuration has critical errors
  2 - Configuration has warnings only

Can be used in CI/CD pipelines to verify configuration before deployment.`,
		Args:         cobra.MaximumNArgs(1),
		SilenceUsage: true,
		RunE: func(_ *cobra.Command, args []string) error {
			path := config.DefaultConfigPath()
			if len(args) > 0 {
				path = args[0]
			}
			cfg, err := config.LoadFrom(path)
			if err != nil {
				return &exitCodeError{code: 1, err: fmt.Errorf("failed to load config: %w", err)}
			}

			validator := config.NewValidator(cfg)
			result := validator.Validate()

			if !result.HasErrors() {
				fmt.Println("Configuration is valid.")
				return nil
			}

			// Print all errors using slog for consistency with ReportValidation
			// but also to stderr for CLI users
			for _, e := range result.Errors {
				if e.Severity == config.SeverityCritical {
					fmt.Fprintf(os.Stderr, "[ERR] %s\n", e.Error())
				} else {
					fmt.Fprintf(os.Stderr, "[WARN] %s\n", e.Error())
				}
			}

			if result.HasCritical() {
				fmt.Fprintln(os.Stderr, "\nConfiguration validation failed.")
				return &exitCodeError{code: 1}
			}

			fmt.Fprintln(os.Stderr, "\nConfiguration has warnings but is valid.")
			return &exitCodeError{code: 2}
		},
	}
	return cmd
}
