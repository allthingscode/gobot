package main

import (
	"fmt"
	"io"
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
	return &cobra.Command{
		Use:   "reformat",
		Short: "Reformat config.json with standard 4-space indentation",
		RunE: func(_ *cobra.Command, _ []string) error {
			path := config.DefaultConfigPath()
			cfg, err := config.LoadFrom(path)
			if err != nil {
				return fmt.Errorf("load config: %w", err)
			}
			if err := cfg.Save(path); err != nil {
				return fmt.Errorf("save config: %w", err)
			}
			fmt.Printf("Successfully reformatted %s\n", path)
			return nil
		},
	}
}

func cmdConfigValidate() *cobra.Command {	cmd := &cobra.Command{
		Use:   "validate",
		Short: "Validate configuration and exit with appropriate code",
		Long: `Validate the current configuration and report any errors.

Returns exit code:
  0 - Configuration is valid
  1 - Configuration has critical errors
  2 - Configuration has warnings only

Can be used in CI/CD pipelines to verify configuration before deployment.`,
		SilenceUsage: true,
		RunE: func(_ *cobra.Command, _ []string) error {
			cfg, err := config.Load()
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

// reportConfigValidation is a helper for cmdRun to keep it clean.
func reportConfigValidation(cfg *config.Config, _ io.Writer) error {
	if err := config.ReportValidation(cfg); err != nil {
		return err
	}
	return nil
}
