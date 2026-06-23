package main

import (
	"bufio"
	"fmt"
	"io"
	"os"
	"strings"

	"github.com/spf13/cobra"
	"golang.org/x/term"

	"github.com/allthingscode/gobot/internal/config"
	"github.com/allthingscode/gobot/internal/doctor"
	"github.com/allthingscode/gobot/internal/secrets"
)

// quickstartOptions holds the resolved flag/env inputs for a quickstart run.
type quickstartOptions struct {
	nonInteractive bool
	telegramToken  string
	allowFrom      []string
	provider       string
	apiKey         string
}

// secretSetter is the minimal vault write surface quickstart needs. The real
// *secrets.SecretsStore satisfies it; tests inject a fake so no DPAPI/AES write
// happens (F-144 AC4: secrets always go through the vault, never plaintext).
type secretSetter interface {
	Set(key, value string) error
}

// quickstartDeps are the injectable collaborators so the collection + reporting
// core is testable without a real terminal, vault, or doctor run.
type quickstartDeps struct {
	in         io.Reader
	out        io.Writer
	configPath string
	store      secretSetter
	isTTY      bool
	readSecret func(prompt string) (string, error)
	readiness  func(*config.Config) (ready bool, remaining []string)
}

func cmdQuickstart() *cobra.Command {
	var opts quickstartOptions
	var allowFromCSV string
	cmd := &cobra.Command{
		Use:   "quickstart",
		Short: "Guided first-run setup: collect required config, store secrets, verify readiness",
		Long: "Guided first-run experience. Collects the genuinely-required inputs (Telegram token,\n" +
			"authorized chat IDs, one LLM provider key), stores secrets in the encrypted vault, writes\n" +
			"the non-secret config, then runs readiness probes and reports either 'ready' or the exact\n" +
			"remaining steps. It does NOT start the agent. Supports a fully non-interactive mode\n" +
			"(--non-interactive with flags/env) and never blocks on a non-TTY.",
		RunE: func(cmd *cobra.Command, _ []string) error {
			opts.allowFrom = splitCSV(allowFromCSV)
			return runQuickstartCmd(cmd, opts)
		},
	}
	f := cmd.Flags()
	f.BoolVar(&opts.nonInteractive, "non-interactive", false, "Never prompt; take values from flags/env and report remaining steps")
	f.StringVar(&opts.telegramToken, "telegram-token", "", "Telegram bot token (or TELEGRAM_BOT_TOKEN)")
	f.StringVar(&allowFromCSV, "allow-from", "", "Comma-separated authorized Telegram chat IDs")
	f.StringVar(&opts.provider, "provider", "", "LLM provider: gemini|anthropic|openai|openrouter (default gemini)")
	f.StringVar(&opts.apiKey, "api-key", "", "API key for the chosen provider (or <PROVIDER>_API_KEY)")
	return cmd
}

// runQuickstartCmd wires the real collaborators (terminal, vault, doctor) and
// delegates to the testable runQuickstart core.
func runQuickstartCmd(cmd *cobra.Command, opts quickstartOptions) error {
	cfg, err := config.Load()
	if err != nil {
		if hint := config.ExplainLoadError(err); hint != "" {
			fmt.Fprintln(cmd.OutOrStdout(), hint)
		}
		return fmt.Errorf("load config: %w", err)
	}
	if err := ensureWorkspace(cmd.OutOrStdout(), cfg); err != nil {
		return err
	}
	deps := quickstartDeps{
		in:         cmd.InOrStdin(),
		out:        cmd.OutOrStdout(),
		configPath: config.DefaultConfigPath(),
		store:      secrets.NewSecretsStore(cfg.StorageRoot()),
		isTTY:      term.IsTerminal(int(os.Stdin.Fd())), //nolint:gosec // stdin file descriptor always fits in int

		readSecret: readSecretFromTerminal,
		readiness:  realReadiness,
	}
	return runQuickstart(deps, opts, cfg)
}

// runQuickstart collects inputs, stores secrets, writes the non-secret config,
// and reports readiness. It mutates cfg in place and persists it only when a
// non-secret field actually changed (AC6 idempotent / non-destructive).
func runQuickstart(deps quickstartDeps, opts quickstartOptions, cfg *config.Config) error {
	interactive := deps.isTTY && !opts.nonInteractive
	if !deps.isTTY && !opts.nonInteractive {
		fmt.Fprintln(deps.out, "No interactive terminal detected; running non-interactively (use flags/env).")
	}
	fmt.Fprintln(deps.out, "gobot quickstart")

	br := bufio.NewReader(deps.in)
	tgChanged, err := applyTelegram(deps, opts, cfg, br, interactive)
	if err != nil {
		return err
	}
	provChanged, err := applyProvider(deps, opts, cfg, br, interactive)
	if err != nil {
		return err
	}

	if tgChanged || provChanged {
		if err := cfg.Save(deps.configPath); err != nil {
			return fmt.Errorf("save config: %w", err)
		}
		fmt.Fprintf(deps.out, "Saved config to %s\n", deps.configPath)
	}
	return reportReadiness(deps, cfg)
}

// applyTelegram resolves the Telegram token + authorized chat IDs and applies
// them: the token goes to the encrypted vault (AC4), allowFrom to config (boot
// auto-reconciles it into the authorization DB, per F-143). Returns whether a
// non-secret config field changed.
func applyTelegram(deps quickstartDeps, opts quickstartOptions, cfg *config.Config, br *bufio.Reader, interactive bool) (bool, error) {
	token, err := resolveSecretInput(deps, interactive, opts.telegramToken, "TELEGRAM_BOT_TOKEN",
		"Telegram bot token (input hidden, blank to skip): ")
	if err != nil {
		return false, fmt.Errorf("read telegram token: %w", err)
	}

	changed := false
	if token != "" {
		if err := deps.store.Set("telegram_token", token); err != nil {
			return false, fmt.Errorf("store telegram token: %w", err)
		}
		fmt.Fprintln(deps.out, "Stored Telegram token in the encrypted vault.")
		if !cfg.Channels.Telegram.Enabled {
			cfg.Channels.Telegram.Enabled = true
			changed = true
		}
	}

	allow := opts.allowFrom
	if len(allow) == 0 && interactive {
		if line := readLine(br, deps.out, "Authorized Telegram chat ID(s), comma-separated (blank to skip): "); line != "" {
			allow = splitCSV(line)
		}
	}
	if len(allow) > 0 && !equalStringSlice(allow, cfg.Channels.Telegram.AllowFrom) {
		cfg.Channels.Telegram.AllowFrom = allow
		changed = true
	}
	return changed, nil
}

// applyProvider resolves the LLM provider + its API key: the key goes to the
// encrypted vault (AC4), the provider name to config. Returns whether a
// non-secret config field changed.
func applyProvider(deps quickstartDeps, opts quickstartOptions, cfg *config.Config, br *bufio.Reader, interactive bool) (bool, error) {
	provider := opts.provider
	if provider == "" && interactive {
		provider = readLine(br, deps.out, "LLM provider [gemini|anthropic|openai|openrouter] (blank for gemini): ")
	}
	if provider == "" {
		provider = "gemini"
	}
	storeKey, envKey, ok := providerKeys(provider)
	if !ok {
		return false, fmt.Errorf("unknown provider %q (want gemini|anthropic|openai|openrouter)", provider)
	}

	apiKey, err := resolveSecretInput(deps, interactive, opts.apiKey, envKey,
		fmt.Sprintf("%s API key (input hidden, blank to skip): ", provider))
	if err != nil {
		return false, fmt.Errorf("read api key: %w", err)
	}
	if apiKey != "" {
		if err := deps.store.Set(storeKey, apiKey); err != nil {
			return false, fmt.Errorf("store api key: %w", err)
		}
		fmt.Fprintf(deps.out, "Stored %s API key in the encrypted vault.\n", provider)
	}

	if cfg.Agents.Defaults.Provider != provider {
		cfg.Agents.Defaults.Provider = provider
		return true, nil
	}
	return false, nil
}

// reportReadiness runs the readiness probes and prints either a ready message or
// a precise remaining-steps list (AC5). It never starts the agent. Returns a
// non-nil error when setup is incomplete so scripts/CI can detect it.
func reportReadiness(deps quickstartDeps, cfg *config.Config) error {
	ready, remaining := deps.readiness(cfg)
	if ready {
		fmt.Fprintln(deps.out, "\nReady. Start the bot with:  gobot run")
		return nil
	}
	fmt.Fprintf(deps.out, "\nNot ready yet - %d step(s) remaining:\n", len(remaining))
	for _, s := range remaining {
		fmt.Fprintf(deps.out, "\n%s\n", s)
	}
	return fmt.Errorf("quickstart: setup incomplete, %d step(s) remaining", len(remaining))
}

// realReadiness combines config validation (telegram token/allowFrom, etc.) and
// the doctor probes (provider key present, storage/secrets reachable) into a
// single ready/remaining verdict. Live connectivity probes are skipped (nil).
func realReadiness(cfg *config.Config) (ready bool, remaining []string) {
	for _, e := range config.NewValidator(cfg).Validate().CriticalErrors() {
		remaining = append(remaining, e.Actionable())
	}
	for _, r := range doctor.GetResults(cfg, nil) {
		if !r.OK && r.Critical {
			remaining = append(remaining, formatDoctorRemaining(r))
		}
	}
	return len(remaining) == 0, remaining
}

func formatDoctorRemaining(r doctor.Result) string {
	fix := r.Remediation
	if fix == "" {
		fix = "see docs/configuration.md"
	}
	return fmt.Sprintf("Problem: %s\n  Fix:   %s\n  Path:  doctor check %q", r.Detail, fix, r.Name)
}

// resolveSecretInput returns the secret from the flag, then the env var, then an
// interactive no-echo prompt. Non-interactive runs with neither flag nor env set
// return "" (the value is reported as a remaining step, never blocked on).
func resolveSecretInput(deps quickstartDeps, interactive bool, flagVal, envKey, prompt string) (string, error) {
	if flagVal != "" {
		return flagVal, nil
	}
	if v := os.Getenv(envKey); v != "" {
		return v, nil
	}
	if interactive {
		return deps.readSecret(prompt)
	}
	return "", nil
}

func readLine(br *bufio.Reader, out io.Writer, prompt string) string {
	fmt.Fprint(out, prompt)
	line, _ := br.ReadString('\n')
	return strings.TrimSpace(line)
}

// readSecretFromTerminal reads a secret without echoing it to the terminal.
func readSecretFromTerminal(prompt string) (string, error) {
	fmt.Fprint(os.Stderr, prompt)
	b, err := term.ReadPassword(int(os.Stdin.Fd())) //nolint:gosec // stdin file descriptor always fits in int
	fmt.Fprintln(os.Stderr)
	if err != nil {
		return "", fmt.Errorf("read secret: %w", err)
	}
	return strings.TrimSpace(string(b)), nil
}

// providerKeys maps a provider name to its vault key and env-var fallback.
func providerKeys(provider string) (storeKey, envKey string, ok bool) {
	switch provider {
	case "gemini":
		return "gemini_api_key", "GEMINI_API_KEY", true
	case "anthropic":
		return "anthropic_api_key", "ANTHROPIC_API_KEY", true
	case "openai":
		return "openai_api_key", "OPENAI_API_KEY", true
	case "openrouter":
		return "openrouter_api_key", "OPENROUTER_API_KEY", true
	default:
		return "", "", false
	}
}

func splitCSV(s string) []string {
	if strings.TrimSpace(s) == "" {
		return nil
	}
	parts := strings.Split(s, ",")
	out := make([]string, 0, len(parts))
	for _, p := range parts {
		if t := strings.TrimSpace(p); t != "" {
			out = append(out, t)
		}
	}
	return out
}

func equalStringSlice(a, b []string) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}
