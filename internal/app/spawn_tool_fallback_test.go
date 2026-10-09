//nolint:testpackage // intentionally uses unexported helpers from main package
package app

import (
	"context"
	"errors"
	"reflect"
	"strings"
	"testing"

	"github.com/allthingscode/gobot/internal/agent"
	"github.com/allthingscode/gobot/internal/config"
	agentctx "github.com/allthingscode/gobot/internal/context"
	"github.com/allthingscode/gobot/internal/provider"
)

type mockFallbackRunner struct {
	responses []string
	errs      []error
	calls     int
}

func (m *mockFallbackRunner) RunText(_ context.Context, _, _, _ string) (string, error) {
	if m.calls >= len(m.responses) {
		return "", errors.New("unexpected call")
	}
	resp := m.responses[m.calls]
	err := m.errs[m.calls]
	m.calls++
	return resp, err
}

func (m *mockFallbackRunner) SetMaxToolIterations(_ int) {}

func (m *mockFallbackRunner) Run(_ context.Context, _, _ string, _ []agentctx.StrategicMessage) (string, []agentctx.StrategicMessage, error) {
	if m.calls >= len(m.responses) {
		return "", nil, errors.New("unexpected call")
	}
	resp := m.responses[m.calls]
	err := m.errs[m.calls]
	m.calls++
	return resp, nil, err
}

type fallbackTestCase struct {
	name            string
	specialistProv  string
	specialistErr   error
	fallbackErr     error
	wantResult      string
	wantErr         string
	expectedRunners int
}

type configuredFallbackAttempt struct {
	provider string
	model    string
}

type configuredFallbackTestCase struct {
	name             string
	specialists      map[string]config.SpecialistConfig
	resultsByModel   map[string]configuredFallbackResult
	wantResult       string
	wantAttempts     []configuredFallbackAttempt
	wantMetaContains []string
}

type configuredFallbackResult struct {
	response string
	err      error
}

func runFallbackTest(t *testing.T, tt fallbackTestCase, defaultProv, specialistProv provider.Provider, resolver provider.Resolver) {
	t.Helper()
	cfg := &config.Config{
		Agents: config.AgentsConfig{
			Specialists: map[string]config.SpecialistConfig{
				RoleResearcher: {Model: "specialist-model", Provider: tt.specialistProv},
			},
		},
	}

	runnerCount := 0
	tool := &SpawnTool{
		Resolver: resolver,
		RunnerFactory: func(prov provider.Provider, _, _ string) agent.Runner {
			runnerCount++
			if runnerCount == 1 {
				resp := "success"
				if tt.specialistErr != nil {
					resp = ""
				}
				return &mockFallbackRunner{
					responses: []string{resp},
					errs:      []error{tt.specialistErr},
				}
			}
			resp := "fallback success"
			if tt.fallbackErr != nil {
				resp = ""
			}
			return &mockFallbackRunner{
				responses: []string{resp},
				errs:      []error{tt.fallbackErr},
			}
		},
		DefaultProv:      defaultProv,
		Model:            "default-model",
		SpecialistModels: map[string]string{RoleResearcher: "specialist-model"},
		Cfg:              cfg,
	}

	res, err := tool.Execute(context.Background(), "sess", "user", map[string]any{
		"agent_type": RoleResearcher,
		"objective":  "do something",
	})

	if tt.wantErr != "" {
		if err == nil || !strings.Contains(err.Error(), tt.wantErr) {
			t.Errorf("expected error containing %q, got %v", tt.wantErr, err)
		}
	} else {
		if err != nil {
			t.Errorf("unexpected error: %v", err)
		}
		if res != tt.wantResult {
			t.Errorf("expected result %q, got %q", tt.wantResult, res)
		}
	}

	if runnerCount != tt.expectedRunners {
		t.Errorf("expected %d runners created, got %d", tt.expectedRunners, runnerCount)
	}
}

func TestSpawnTool_Execute_Fallback(t *testing.T) {
	t.Parallel()
	registry := provider.NewRegistry()
	const defaultProvName = "default-prov"
	const specialistProvName = "specialist-prov"

	defaultProv := &mockNamedProvider{name: defaultProvName}
	specialistProv := &mockNamedProvider{name: specialistProvName}
	if err := registry.Register(defaultProv); err != nil {
		t.Fatalf("register default provider: %v", err)
	}
	if err := registry.Register(specialistProv); err != nil {
		t.Fatalf("register specialist provider: %v", err)
	}

	tests := []fallbackTestCase{
		{
			name:            "specialist succeeds, no fallback",
			specialistProv:  specialistProvName,
			specialistErr:   nil,
			wantResult:      "success",
			wantErr:         "",
			expectedRunners: 1,
		},
		{
			name:            "specialist fails, same provider as default, no fallback",
			specialistProv:  defaultProvName, // same as default
			specialistErr:   errors.New("original error"),
			wantErr:         "original error",
			expectedRunners: 1,
		},
		{
			name:            "specialist fails, different provider, fallback succeeds",
			specialistProv:  specialistProvName,
			specialistErr:   errors.New("specialist error"),
			fallbackErr:     nil,
			wantResult:      "fallback success",
			wantErr:         "",
			expectedRunners: 2,
		},
		{
			name:            "specialist fails, different provider, fallback also fails",
			specialistProv:  specialistProvName,
			specialistErr:   errors.New("specialist error"),
			fallbackErr:     errors.New("fallback error"),
			wantErr:         "specialist error", // original error should be returned
			expectedRunners: 2,
		},
	}

	for _, tt := range tests {
		tt := tt
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			runFallbackTest(t, tt, defaultProv, specialistProv, registry)
		})
	}
}

func TestSpawnTool_Execute_ConfiguredModelFallbacks(t *testing.T) {
	t.Parallel()
	registry := provider.NewRegistry()
	const (
		defaultProvName = "default-prov"
		altProvName     = "alt-prov"
	)

	defaultProv := &mockNamedProvider{name: defaultProvName}
	altProv := &mockNamedProvider{name: altProvName}
	if err := registry.Register(defaultProv); err != nil {
		t.Fatalf("register default provider: %v", err)
	}
	if err := registry.Register(altProv); err != nil {
		t.Fatalf("register alt provider: %v", err)
	}

	for _, tt := range configuredFallbackTestCases(defaultProvName, altProvName) {
		tt := tt
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			runConfiguredFallbackTest(t, tt, defaultProv, registry)
		})
	}
}

func configuredFallbackTestCases(defaultProvName, altProvName string) []configuredFallbackTestCase {
	return []configuredFallbackTestCase{
		configuredFallbackSuccessCase(defaultProvName),
		configuredFallbackDuplicateSkipCase(defaultProvName),
		configuredFallbackEscalationCase(defaultProvName),
		configuredFallbackAlternateProviderCase(defaultProvName, altProvName),
	}
}

func configuredFallbackSuccessCase(defaultProvName string) configuredFallbackTestCase {
	const (
		primaryModel  = "research-primary"
		fallbackModel = "research-fallback"
	)

	return configuredFallbackTestCase{
		name: "fallback succeeds after primary specialist model fails",
		specialists: map[string]config.SpecialistConfig{
			RoleResearcher:               {Model: primaryModel},
			RoleResearcher + "_fallback": {Model: fallbackModel},
		},
		resultsByModel: map[string]configuredFallbackResult{
			primaryModel:  {err: errors.New("primary failed")},
			fallbackModel: {response: "fallback success"},
		},
		wantResult: "fallback success",
		wantAttempts: []configuredFallbackAttempt{
			{provider: defaultProvName, model: primaryModel},
			{provider: defaultProvName, model: fallbackModel},
		},
		wantMetaContains: []string{
			"agent_type: researcher",
			"fallback_key: researcher_fallback",
			"model: research-fallback",
			"provider: default-prov",
		},
	}
}

func configuredFallbackDuplicateSkipCase(defaultProvName string) configuredFallbackTestCase {
	const (
		primaryModel    = "research-primary"
		escalationModel = "research-escalation"
	)

	return configuredFallbackTestCase{
		name: "duplicate fallback model is skipped before escalation succeeds",
		specialists: map[string]config.SpecialistConfig{
			RoleResearcher:                 {Model: primaryModel},
			RoleResearcher + "_fallback":   {Model: primaryModel},
			RoleResearcher + "_escalation": {Model: escalationModel},
		},
		resultsByModel: map[string]configuredFallbackResult{
			primaryModel:    {err: errors.New("primary failed")},
			escalationModel: {response: "escalation success"},
		},
		wantResult: "escalation success",
		wantAttempts: []configuredFallbackAttempt{
			{provider: defaultProvName, model: primaryModel},
			{provider: defaultProvName, model: escalationModel},
		},
		wantMetaContains: []string{
			"fallback_key: researcher_escalation",
			"model: research-escalation",
		},
	}
}

func configuredFallbackEscalationCase(defaultProvName string) configuredFallbackTestCase {
	const (
		primaryModel    = "research-primary"
		fallbackModel   = "research-fallback"
		escalationModel = "research-escalation"
	)

	return configuredFallbackTestCase{
		name: "fallback failure progresses to escalation",
		specialists: map[string]config.SpecialistConfig{
			RoleResearcher:                 {Model: primaryModel},
			RoleResearcher + "_fallback":   {Model: fallbackModel},
			RoleResearcher + "_escalation": {Model: escalationModel},
		},
		resultsByModel: map[string]configuredFallbackResult{
			primaryModel:    {err: errors.New("primary failed")},
			fallbackModel:   {err: errors.New("fallback failed")},
			escalationModel: {response: "escalation success"},
		},
		wantResult: "escalation success",
		wantAttempts: []configuredFallbackAttempt{
			{provider: defaultProvName, model: primaryModel},
			{provider: defaultProvName, model: fallbackModel},
			{provider: defaultProvName, model: escalationModel},
		},
		wantMetaContains: []string{
			"fallback_key: researcher_escalation",
			"model: research-escalation",
		},
	}
}

func configuredFallbackAlternateProviderCase(defaultProvName, altProvName string) configuredFallbackTestCase {
	const (
		primaryModel  = "research-primary"
		fallbackModel = "research-fallback"
	)

	return configuredFallbackTestCase{
		name: "fallback uses its configured alternate provider",
		specialists: map[string]config.SpecialistConfig{
			RoleResearcher:               {Model: primaryModel},
			RoleResearcher + "_fallback": {Model: fallbackModel, Provider: altProvName},
		},
		resultsByModel: map[string]configuredFallbackResult{
			primaryModel:  {err: errors.New("primary failed")},
			fallbackModel: {response: "alternate provider fallback success"},
		},
		wantResult: "alternate provider fallback success",
		wantAttempts: []configuredFallbackAttempt{
			{provider: defaultProvName, model: primaryModel},
			{provider: altProvName, model: fallbackModel},
		},
		wantMetaContains: []string{
			"fallback_key: researcher_fallback",
			"model: research-fallback",
			"provider: alt-prov",
		},
	}
}

func runConfiguredFallbackTest(t *testing.T, tt configuredFallbackTestCase, defaultProv provider.Provider, resolver provider.Resolver) {
	t.Helper()

	cfg := &config.Config{
		Agents: config.AgentsConfig{
			Specialists: tt.specialists,
		},
	}

	var attempts []configuredFallbackAttempt
	tool := &SpawnTool{
		Resolver: resolver,
		RunnerFactory: func(prov provider.Provider, model, _ string) agent.Runner {
			attempts = append(attempts, configuredFallbackAttempt{
				provider: prov.Name(),
				model:    model,
			})
			result := tt.resultsByModel[model]
			return &mockFallbackRunner{
				responses: []string{result.response},
				errs:      []error{result.err},
			}
		},
		DefaultProv:      defaultProv,
		Model:            "default-model",
		SpecialistModels: map[string]string{RoleResearcher: tt.specialists[RoleResearcher].Model},
		Cfg:              cfg,
	}

	ctx, meta := withToolMeta(context.Background())
	got, err := tool.Execute(ctx, "sess", "user", map[string]any{
		"agent_type": RoleResearcher,
		"objective":  "research something",
	})
	if err != nil {
		t.Fatalf("Execute failed: %v", err)
	}
	if got != tt.wantResult {
		t.Fatalf("Execute result = %q, want %q", got, tt.wantResult)
	}
	if !reflect.DeepEqual(attempts, tt.wantAttempts) {
		t.Fatalf("attempts = %#v, want %#v", attempts, tt.wantAttempts)
	}

	formatted := formatToolMetaBlock(got, meta)
	for _, want := range tt.wantMetaContains {
		if !strings.Contains(formatted, want) {
			t.Errorf("formatted metadata missing %q in:\n%s", want, formatted)
		}
	}
}

//nolint:gocognit,cyclop // Keep cross-owner setup and provider identity assertions together.
func TestSpawnTool_IndependentFallbackOwners(t *testing.T) {
	t.Parallel()
	for _, owner := range []string{"owner-a", "owner-b"} {
		t.Run(owner, func(t *testing.T) {
			t.Parallel()
			parent := &mockNamedProvider{name: "parent"}
			specialist := &mockNamedProvider{name: "specialist"}
			alternate := &mockNamedProvider{name: "alternate"}
			registry := provider.NewRegistry()
			for _, prov := range []provider.Provider{specialist, alternate} {
				if err := registry.Register(prov); err != nil {
					t.Fatal(err)
				}
			}
			cfg := &config.Config{}
			cfg.Agents.Specialists = map[string]config.SpecialistConfig{
				RoleResearcher:                 {Provider: "specialist", Model: "primary"},
				RoleResearcher + "_fallback":   {Provider: "alternate", Model: "fallback"},
				RoleResearcher + "_escalation": {Provider: "alternate", Model: "escalation"},
			}
			for _, successModel := range []string{"parent-model", "fallback", "escalation"} {
				t.Run(successModel, func(t *testing.T) {
					t.Parallel()
					wantProviders := []provider.Provider{specialist, parent, alternate, alternate}
					wantModels := []string{"primary", "parent-model", "fallback", "escalation"}
					attempts := 0
					tool := newSpawnTool(parent, "parent-model", nil, map[string]string{RoleResearcher: "primary"}, nil, cfg, registry)
					tool.RunnerFactory = func(prov provider.Provider, model, _ string) agent.Runner {
						if attempts >= len(wantModels) || prov != wantProviders[attempts] || model != wantModels[attempts] {
							t.Fatalf("incorrect attempt %d: %v/%s", attempts, prov, model)
						}
						attempts++
						if model == successModel {
							return &mockSubAgentRunner{response: owner}
						}
						return &mockSubAgentRunner{err: errors.New("retry")}
					}
					ctx, meta := withToolMeta(context.Background())
					got, err := tool.Execute(ctx, "session", "user", map[string]any{"objective": "work"})
					if err != nil || got != owner {
						t.Fatalf("Execute = %q, %v", got, err)
					}
					if !strings.Contains(formatToolMetaBlock(got, meta), "model: "+successModel) {
						t.Fatal("fallback metadata lost")
					}
					if wantModels[attempts-1] != successModel {
						t.Fatal("sequence ended before success model")
					}
				})
			}
		})
	}
}
