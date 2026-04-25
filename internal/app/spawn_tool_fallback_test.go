//nolint:testpackage // intentionally uses unexported helpers from main package
package app

import (
	"context"
	"errors"
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
	name             string
	specialistProv   string
	specialistErr    error
	fallbackErr      error
	wantResult       string
	wantErr          string
	expectedRunners  int
}

func runFallbackTest(t *testing.T, tt fallbackTestCase, defaultProv, specialistProv provider.Provider) {
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

//nolint:paralleltest // uses global state
func TestSpawnTool_Execute_Fallback(t *testing.T) {
	const defaultProvName = "default-prov"
	const specialistProvName = "specialist-prov"

	defaultProv := &mockNamedProvider{name: defaultProvName}
	specialistProv := &mockNamedProvider{name: specialistProvName}

	provider.ResetForTest()
	t.Cleanup(provider.ResetForTest)
	if err := provider.Register(defaultProv); err != nil {
		t.Fatalf("register default provider: %v", err)
	}
	if err := provider.Register(specialistProv); err != nil {
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
			runFallbackTest(t, tt, defaultProv, specialistProv)
		})
	}
}
