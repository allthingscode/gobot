//nolint:testpackage // exercises unexported quickstart core helpers from the main package
package main

import (
	"bytes"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/allthingscode/gobot/internal/config"
	"github.com/allthingscode/gobot/internal/doctor"
)

// fakeStore captures vault writes so tests can assert secrets went through the
// vault (AC4) without touching DPAPI/AES.
type fakeStore struct {
	sets map[string]string
}

func (f *fakeStore) Set(key, value string) error {
	f.sets[key] = value
	return nil
}

func readyAlways(*config.Config) (ready bool, remaining []string) { return true, nil }

func neutralizeSecretEnv(t *testing.T) {
	t.Helper()
	for _, e := range []string{
		"TELEGRAM_BOT_TOKEN", "GEMINI_API_KEY", "ANTHROPIC_API_KEY",
		"OPENAI_API_KEY", "OPENROUTER_API_KEY", "GOOGLE_API_KEY",
	} {
		t.Setenv(e, "")
	}
}

//nolint:paralleltest // mutates process env via t.Setenv for deterministic secret resolution
func TestQuickstart_NonInteractive_StoresSecretsInVaultAndReportsReady(t *testing.T) {
	neutralizeSecretEnv(t)
	cfgPath := filepath.Join(t.TempDir(), "config.json")
	store := &fakeStore{sets: map[string]string{}}
	var out bytes.Buffer
	deps := quickstartDeps{
		in:         strings.NewReader(""),
		out:        &out,
		configPath: cfgPath,
		store:      store,
		isTTY:      false,
		readSecret: func(string) (string, error) { return "", errors.New("must not prompt in non-interactive mode") },
		readiness:  readyAlways,
	}
	opts := quickstartOptions{
		nonInteractive: true,
		telegramToken:  "123:abc",
		allowFrom:      []string{"111", "222"},
		provider:       "gemini",
		apiKey:         "AIzaSyTESTKEY1234567890",
	}

	require.NoError(t, runQuickstart(deps, opts, &config.Config{}))

	// AC4: secrets stored in the vault, keyed canonically.
	assert.Equal(t, "123:abc", store.sets["telegram_token"])
	assert.Equal(t, "AIzaSyTESTKEY1234567890", store.sets["gemini_api_key"])

	// Non-secret config persisted; secrets NEVER written to plaintext config.
	saved, err := config.LoadFrom(cfgPath)
	require.NoError(t, err)
	assert.True(t, saved.Channels.Telegram.Enabled)
	assert.Equal(t, []string{"111", "222"}, saved.Channels.Telegram.AllowFrom)
	assert.Equal(t, "gemini", saved.Agents.Defaults.Provider)
	assert.Empty(t, saved.Channels.Telegram.Token, "token must not be in plaintext config")
	assert.Empty(t, saved.Providers.Gemini.APIKey, "api key must not be in plaintext config")

	assert.Contains(t, out.String(), "Ready")
}

//nolint:paralleltest // mutates process env via t.Setenv for deterministic secret resolution
func TestQuickstart_NonTTY_DoesNotPromptAndAnnouncesNonInteractive(t *testing.T) {
	neutralizeSecretEnv(t)
	var out bytes.Buffer
	deps := quickstartDeps{
		in:         strings.NewReader(""),
		out:        &out,
		configPath: filepath.Join(t.TempDir(), "config.json"),
		store:      &fakeStore{sets: map[string]string{}},
		isTTY:      false, // not a terminal, and --non-interactive NOT set
		readSecret: func(string) (string, error) { return "", errors.New("must not prompt on non-TTY") },
		readiness:  readyAlways,
	}
	opts := quickstartOptions{telegramToken: "9:x", provider: "openai", apiKey: "sk-x"}

	// Must not hang or call readSecret; must announce the non-interactive fallback.
	require.NoError(t, runQuickstart(deps, opts, &config.Config{}))
	assert.Contains(t, out.String(), "No interactive terminal detected")
}

//nolint:paralleltest // mutates process env via t.Setenv for deterministic secret resolution
func TestQuickstart_NonInteractive_MissingInputs_ReportsRemainingAndErrors(t *testing.T) {
	neutralizeSecretEnv(t)
	var out bytes.Buffer
	remaining := []string{"Problem: no API key configured\n  Fix:   run quickstart with --api-key\n  Path:  providers.api_key"}
	deps := quickstartDeps{
		in:         strings.NewReader(""),
		out:        &out,
		configPath: filepath.Join(t.TempDir(), "config.json"),
		store:      &fakeStore{sets: map[string]string{}},
		isTTY:      false,
		readSecret: func(string) (string, error) { return "", errors.New("must not prompt") },
		readiness:  func(*config.Config) (bool, []string) { return false, remaining },
	}

	err := runQuickstart(deps, quickstartOptions{nonInteractive: true}, &config.Config{})
	require.Error(t, err)
	assert.Contains(t, err.Error(), "setup incomplete")
	assert.Contains(t, out.String(), "remaining")
	assert.Contains(t, out.String(), "providers.api_key")
}

//nolint:paralleltest // mutates process env via t.Setenv for deterministic secret resolution
func TestQuickstart_NonInteractive_IsIdempotentAndNonDestructive(t *testing.T) {
	neutralizeSecretEnv(t)
	cfgPath := filepath.Join(t.TempDir(), "config.json")
	store := &fakeStore{sets: map[string]string{}}
	opts := quickstartOptions{
		nonInteractive: true,
		telegramToken:  "123:abc",
		allowFrom:      []string{"111"},
		provider:       "gemini",
		apiKey:         "AIzaKEY",
	}
	newDeps := func(out *bytes.Buffer) quickstartDeps {
		return quickstartDeps{
			in: strings.NewReader(""), out: out, configPath: cfgPath, store: store, isTTY: false,
			readSecret: func(string) (string, error) { return "", errors.New("no prompt") },
			readiness:  readyAlways,
		}
	}

	cfg := &config.Config{}
	require.NoError(t, runQuickstart(newDeps(&bytes.Buffer{}), opts, cfg))
	first, err := os.ReadFile(cfgPath)
	require.NoError(t, err)

	// Second run with identical inputs must not rewrite the config file.
	var out2 bytes.Buffer
	require.NoError(t, runQuickstart(newDeps(&out2), opts, cfg))
	second, err := os.ReadFile(cfgPath)
	require.NoError(t, err)

	assert.Equal(t, first, second, "re-running quickstart must be non-destructive")
	assert.NotContains(t, out2.String(), "Saved config", "no save expected when nothing changed")
}

//nolint:paralleltest // mutates process env via t.Setenv for deterministic secret resolution
func TestQuickstart_Interactive_CollectsTokenKeyAndPlainInputs(t *testing.T) {
	neutralizeSecretEnv(t)
	cfgPath := filepath.Join(t.TempDir(), "config.json")
	store := &fakeStore{sets: map[string]string{}}
	// Plain stdin supplies allowFrom then provider; readSecret supplies token then api key.
	secretsSeq := []string{"999:tok", "sk-secret"}
	idx := 0
	var out bytes.Buffer
	deps := quickstartDeps{
		in:         strings.NewReader("333,444\nopenai\n"),
		out:        &out,
		configPath: cfgPath,
		store:      store,
		isTTY:      true, // interactive
		readSecret: func(string) (string, error) {
			v := secretsSeq[idx]
			idx++
			return v, nil
		},
		readiness: readyAlways,
	}

	require.NoError(t, runQuickstart(deps, quickstartOptions{}, &config.Config{}))

	assert.Equal(t, "999:tok", store.sets["telegram_token"])
	assert.Equal(t, "sk-secret", store.sets["openai_api_key"])
	saved, err := config.LoadFrom(cfgPath)
	require.NoError(t, err)
	assert.Equal(t, []string{"333", "444"}, saved.Channels.Telegram.AllowFrom)
	assert.Equal(t, "openai", saved.Agents.Defaults.Provider)
	assert.True(t, saved.Channels.Telegram.Enabled)
}

//nolint:paralleltest // mutates process env via t.Setenv for deterministic secret resolution
func TestQuickstart_UnknownProvider_Errors(t *testing.T) {
	neutralizeSecretEnv(t)
	deps := quickstartDeps{
		in: strings.NewReader(""), out: &bytes.Buffer{},
		configPath: filepath.Join(t.TempDir(), "config.json"),
		store:      &fakeStore{sets: map[string]string{}}, isTTY: false,
		readSecret: func(string) (string, error) { return "", nil },
		readiness:  readyAlways,
	}
	err := runQuickstart(deps, quickstartOptions{nonInteractive: true, provider: "bogus"}, &config.Config{})
	require.Error(t, err)
	assert.Contains(t, err.Error(), "unknown provider")
}

//nolint:paralleltest // mutates process env via t.Setenv for deterministic secret resolution
func TestQuickstartCmd_MalformedConfig_PrintsActionableHint(t *testing.T) {
	neutralizeSecretEnv(t)
	home := t.TempDir()
	t.Setenv("GOBOT_HOME", home)
	t.Setenv("GOBOT_STORAGE", t.TempDir())
	cfgPath := filepath.Join(home, ".gobot", "config.json")
	require.NoError(t, os.MkdirAll(filepath.Dir(cfgPath), 0o755))
	require.NoError(t, os.WriteFile(cfgPath, []byte("{ this is not valid json "), 0o600))

	cmd := cmdQuickstart()
	var out bytes.Buffer
	cmd.SetOut(&out)
	cmd.SetErr(&out)
	cmd.SetIn(strings.NewReader(""))
	cmd.SetArgs([]string{"--non-interactive"})

	err := cmd.Execute()
	require.Error(t, err)
	assert.Contains(t, out.String(), "not valid JSON")
	assert.Contains(t, out.String(), cfgPath)
}

//nolint:paralleltest // mutates process env via t.Setenv for deterministic secret resolution
func TestQuickstartCmd_FullWiring_NonInteractive_ReportsRemaining(t *testing.T) {
	neutralizeSecretEnv(t)
	// realReadiness -> doctor.GetResults opens the checkpoint sqlite DB, whose handle
	// outlives the test on Windows; use os.MkdirTemp + best-effort cleanup (like
	// TestCmdRunAutoInit) so a locked checkpoints.db does not fail the test.
	home, err := os.MkdirTemp("", "gobot-qs-home-*")
	require.NoError(t, err)
	defer func() { _ = os.RemoveAll(home) }()
	storage, err := os.MkdirTemp("", "gobot-qs-storage-*")
	require.NoError(t, err)
	defer func() { _ = os.RemoveAll(storage) }()
	t.Setenv("GOBOT_HOME", home)
	t.Setenv("GOBOT_STORAGE", storage)

	cmd := cmdQuickstart()
	var out bytes.Buffer
	cmd.SetOut(&out)
	cmd.SetErr(&out)
	cmd.SetIn(strings.NewReader(""))
	cmd.SetArgs([]string{"--non-interactive"})

	// No provider key supplied -> readiness must report at least one remaining step.
	err = cmd.Execute()
	require.Error(t, err)
	assert.Contains(t, out.String(), "remaining")
}

func TestProviderKeys_AllProvidersAndUnknown(t *testing.T) {
	t.Parallel()
	cases := map[string]struct {
		store, env string
		ok         bool
	}{
		"gemini":     {"gemini_api_key", "GEMINI_API_KEY", true},
		"anthropic":  {"anthropic_api_key", "ANTHROPIC_API_KEY", true},
		"openai":     {"openai_api_key", "OPENAI_API_KEY", true},
		"openrouter": {"openrouter_api_key", "OPENROUTER_API_KEY", true},
		"bogus":      {"", "", false},
	}
	for name, want := range cases {
		store, env, ok := providerKeys(name)
		assert.Equal(t, want.ok, ok, name)
		assert.Equal(t, want.store, store, name)
		assert.Equal(t, want.env, env, name)
	}
}

func TestFormatDoctorRemaining_FallbackFix(t *testing.T) {
	t.Parallel()
	withFix := formatDoctorRemaining(doctor.Result{Name: "x", Detail: "d", Remediation: "do y"})
	assert.Contains(t, withFix, "Fix:   do y")
	assert.Contains(t, withFix, "Problem: d")
	noFix := formatDoctorRemaining(doctor.Result{Name: "x", Detail: "d"})
	assert.Contains(t, noFix, "see docs/configuration.md")
}

func TestEqualStringSliceAndSplitCSV(t *testing.T) {
	t.Parallel()
	assert.True(t, equalStringSlice([]string{"a", "b"}, []string{"a", "b"}))
	assert.False(t, equalStringSlice([]string{"a"}, []string{"a", "b"}))
	assert.False(t, equalStringSlice([]string{"a", "b"}, []string{"a", "c"}))
	assert.Equal(t, []string{"1", "2"}, splitCSV(" 1 , 2 ,"))
	assert.Nil(t, splitCSV("   "))
}
