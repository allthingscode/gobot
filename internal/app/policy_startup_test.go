//nolint:testpackage // Verifies internal startup ordering and hook mutation.
package app

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/allthingscode/gobot/internal/agent"
	"github.com/allthingscode/gobot/internal/config"
	agentctx "github.com/allthingscode/gobot/internal/context"
)

const invalidPolicyState = "invalid"

//nolint:gocognit,cyclop,funlen // Path-state matrix verifies failure atomicity and independent policy/HITL enforcement.
func TestSetupHooksPolicyPaths(t *testing.T) {
	t.Parallel()
	tests := []struct {
		name, state                  string
		explicit, wantError, missing bool
	}{
		{"optional absent", "absent", false, false, false},
		{"implicit valid", "valid", false, false, false},
		{"implicit invalid", invalidPolicyState, false, true, false},
		{"implicit unreadable", "directory", false, true, false},
		{"explicit absent default", "absent", true, true, true},
		{"explicit valid", "valid", true, false, false},
		{"explicit invalid", invalidPolicyState, true, true, false},
		{"explicit unreadable", "directory", true, true, false},
		{"old fixture", "policies", true, true, false},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			cfg := &config.Config{}
			cfg.Runtime.StorageRoot = t.TempDir()
			cfg.Tools.HighRisk = []string{"risky"}
			path := filepath.Join(cfg.StorageRoot(), "tool_policy.yaml")
			switch tt.state {
			case "valid", invalidPolicyState, "policies":
				content := "rules: [{tool: denied, decision: deny}, {tool: approval, decision: require_hitl}]"
				if tt.state == invalidPolicyState {
					content = "rules: null"
				}
				if tt.state == "policies" {
					content = "policies: [{name: test, tool: '*', decision: allow}]"
				}
				if err := os.WriteFile(path, []byte(content), 0o600); err != nil {
					t.Fatal(err)
				}
			case "directory":
				if err := os.Mkdir(path, 0o700); err != nil {
					t.Fatal(err)
				}
			}
			if tt.explicit {
				cfg.Runtime.PolicyFilePath = path
			}
			old := &agent.Hooks{}
			runner := &AgentRunner{Hooks: old}
			mgr := &agent.SessionManager{}
			hooks, hitl, err := SetupHooks(cfg, runner, mgr, nil, nil)
			if tt.wantError {
				if err == nil || hooks != nil || hitl != nil || runner.Hooks != old {
					t.Fatalf("failure mutated hooks or returned usable state: %v", err)
				}
				if !strings.Contains(err.Error(), strconv.Quote(path)) {
					t.Fatalf("missing path context: %v", err)
				}
				if tt.missing && !errors.Is(err, os.ErrNotExist) {
					t.Fatalf("lost missing-file cause: %v", err)
				}
				return
			}
			if err != nil || hooks == nil || hitl == nil {
				t.Fatalf("setup: %v", err)
			}
			if _, err := hooks.RunPreTool(context.Background(), "cli:test", "ordinary", nil); err != nil {
				t.Fatalf("unmatched tool: %v", err)
			}
			if _, err := hooks.RunPreTool(context.Background(), "cli:test", "risky", nil); err == nil {
				t.Fatal("independent high-risk HITL must deny")
			}
			if tt.state == "valid" {
				for _, tool := range []string{"denied", "approval"} {
					if _, err := hooks.RunPreTool(context.Background(), "cli:test", tool, nil); err == nil {
						t.Fatalf("%s must deny without approval", tool)
					}
				}
			}
		})
	}
}

//nolint:gocognit,cyclop // Startup failure matrix asserts no hooks, idempotency, or readiness publication.
func TestRunAgentLoopPolicyFailureBeforeServices(t *testing.T) {
	t.Parallel()
	for _, state := range []string{"missing", invalidPolicyState, "directory"} {
		t.Run(state, func(t *testing.T) {
			t.Parallel()
			cfg := &config.Config{}
			cfg.Runtime.StorageRoot = t.TempDir()
			cfg.Runtime.PolicyFilePath = filepath.Join(cfg.StorageRoot(), "policy.yaml")
			if state == invalidPolicyState {
				if err := os.WriteFile(cfg.Runtime.PolicyFilePath, []byte("policies: []"), 0o600); err != nil {
					t.Fatal(err)
				}
			}
			if state == "directory" {
				if err := os.Mkdir(cfg.Runtime.PolicyFilePath, 0o700); err != nil {
					t.Fatal(err)
				}
			}
			checkpoints, err := agentctx.GetCheckpointManager(cfg.StorageRoot())
			if err != nil {
				t.Fatal(err)
			}
			t.Cleanup(func() {
				if err := checkpoints.DB().Close(); err != nil {
					t.Error(err)
				}
			})
			cfg.Gateway.Enabled = true
			cfg.Gateway.Host = "invalid host"
			cfg.Gateway.Port = 1
			runner := &AgentRunner{}
			stack := &AgentStack{Runner: runner, Model: "test"}
			ctx, cancel := context.WithTimeout(context.Background(), time.Second)
			defer cancel()
			err = runAgentLoop(ctx, cfg, stack, nil, nil, nil, nil, time.Now())
			if err == nil || !strings.Contains(err.Error(), "run agent: setup hooks:") {
				t.Fatalf("expected startup policy failure, got %v", err)
			}
			if runner.Hooks != nil || runner.IdempStore != nil {
				t.Fatal("hooks/idempotency must not start on invalid policy")
			}
			if _, err := os.Stat(startupMarkerPath(cfg.StorageRoot())); !errors.Is(err, os.ErrNotExist) {
				t.Fatalf("readiness artifact published: %v", err)
			}
		})
	}
}

func TestRuntimeCheckpointStoreUnavailable(t *testing.T) {
	t.Parallel()
	path := filepath.Join(t.TempDir(), "file")
	if err := os.WriteFile(path, []byte("not a directory"), 0o600); err != nil {
		t.Fatal(err)
	}
	if store := runtimeCheckpointStore(path); store != nil {
		t.Fatal("unavailable checkpoints must remain optional")
	}
}
