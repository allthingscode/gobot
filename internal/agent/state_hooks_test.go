//nolint:testpackage // requires unexported mock types for testing
package agent

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/allthingscode/gobot/internal/state"
)

//nolint:gocognit,cyclop // Table matrices inspect persisted lifecycle state and failure evidence together.
func TestStateHook_PersistedLifecycle(t *testing.T) {
	t.Parallel()
	for _, success := range []bool{true, false} {
		for _, steps := range []int{0, 1, 3} {
			t.Run(fmt.Sprintf("success=%t/steps=%d", success, steps), func(t *testing.T) {
				t.Parallel()
				dir := t.TempDir()
				cfg := state.ManagerConfig{StateDir: dir, LockTimeout: time.Second}
				mgr := state.NewManager(cfg)
				if err := mgr.Init(); err != nil {
					t.Fatal(err)
				}
				hook := NewStateHook(mgr)
				ctx := context.Background()
				id := state.WorkflowID("persisted")
				data := json.RawMessage(`{"step":0}`)
				if _, err := hook.OnWorkflowStart(ctx, id, data); err != nil {
					t.Fatal(err)
				}
				if steps > 0 {
					journal, err := state.OpenJournal(filepath.Join(dir, "workflows"), id)
					if err != nil {
						t.Fatal(err)
					}
					if err := journal.Append(state.JournalEntry{Timestamp: time.Now(), Operation: "data_update", Payload: json.RawMessage(`{"step":-1}`)}); err != nil {
						t.Fatal(err)
					}
					if err := journal.Close(); err != nil {
						t.Fatal(err)
					}
				}
				for step := 1; step <= steps; step++ {
					data = json.RawMessage(fmt.Sprintf(`{"step":%d}`, step))
					if err := hook.OnStepComplete(ctx, id, data); err != nil {
						t.Fatal(err)
					}
					loaded, err := mgr.LoadWorkflow(id)
					if err != nil {
						t.Fatal(err)
					}
					if loaded.Status != state.StatusRunning || strings.Join(strings.Fields(string(loaded.Data)), "") != string(data) || loaded.Version != 2+step {
						t.Fatalf("checkpoint: %+v", loaded)
					}
					reopened, err := state.NewManager(cfg).LoadWithRecovery(id)
					if err != nil {
						t.Fatal(err)
					}
					if reopened.Status != state.StatusRunning || strings.Join(strings.Fields(string(reopened.Data)), "") != string(data) {
						t.Fatalf("reopened: %+v", reopened)
					}
				}
				if err := hook.OnWorkflowComplete(ctx, id, success); err != nil {
					t.Fatal(err)
				}
				var archived state.WorkflowState
				if err := state.ReadFileJSON(filepath.Join(dir, "archived", string(id)+".json"), &archived); err != nil {
					t.Fatal(err)
				}
				want := state.StatusFailed
				if success {
					want = state.StatusCompleted
				}
				if archived.Status != want || strings.Join(strings.Fields(string(archived.Data)), "") != string(data) || archived.Version != 2+steps {
					t.Fatalf("archive: %+v", archived)
				}
				ids, err := mgr.ListActive()
				if err != nil || len(ids) != 0 {
					t.Fatalf("active: %v, %v", ids, err)
				}
				if _, err := os.Stat(filepath.Join(dir, "workflows", string(id)+".journal")); !os.IsNotExist(err) {
					t.Fatalf("journal remains: %v", err)
				}
			})
		}
	}
}

//nolint:gocognit,cyclop // Table matrices inspect persisted lifecycle state and failure evidence together.
func TestStateHook_StepFailureAndCrashRecovery(t *testing.T) {
	t.Parallel()
	for _, completedStep := range []bool{false, true} {
		t.Run(fmt.Sprintf("completedStep=%t", completedStep), func(t *testing.T) {
			t.Parallel()
			hook := newTestHook(t)
			ctx := context.Background()
			id := state.WorkflowID("retry")
			if _, err := hook.OnWorkflowStart(ctx, id, json.RawMessage(`{"step":0}`)); err != nil {
				t.Fatal(err)
			}
			if completedStep {
				if err := hook.OnStepComplete(ctx, id, json.RawMessage(`{"step":1}`)); err != nil {
					t.Fatal(err)
				}
			}
			before, err := hook.manager.LoadWithRecovery(id)
			if err != nil {
				t.Fatal(err)
			}
			err = hook.OnStepComplete(ctx, id, json.RawMessage(`{`))
			if err == nil || errors.Unwrap(err) == nil || !strings.Contains(err.Error(), "saving checkpoint") {
				t.Fatalf("checkpoint error: %v", err)
			}
			after, err := hook.manager.LoadWithRecovery(id)
			if err != nil {
				t.Fatal(err)
			}
			if after.Status != state.StatusRunning || string(after.Data) != string(before.Data) || after.Version != before.Version {
				t.Fatalf("failure changed evidence: %+v", after)
			}
			if err := hook.OnStepComplete(ctx, id, json.RawMessage(`{"step":2}`)); err != nil {
				t.Fatal(err)
			}
			recovered, err := hook.RecoverWorkflow(ctx, id)
			if err != nil {
				t.Fatal(err)
			}
			persisted, err := hook.manager.LoadWorkflow(id)
			if err != nil {
				t.Fatal(err)
			}
			if recovered.Status != state.StatusFailed || persisted.Status != state.StatusFailed || strings.Join(strings.Fields(string(persisted.Data)), "") != `{"step":2}` {
				t.Fatalf("crash recovery: %+v, %+v", recovered, persisted)
			}
		})
	}
}

func newTestHook(t *testing.T) *StateHook {
	t.Helper()
	cfg := state.ManagerConfig{
		StateDir:    t.TempDir(),
		LockTimeout: 5 * time.Second,
		MaxRetries:  3,
	}
	mgr := state.NewManager(cfg)
	if err := mgr.Init(); err != nil {
		t.Fatalf("manager.Init: %v", err)
	}
	return NewStateHook(mgr)
}

func TestStateHook_WorkflowLifecycle(t *testing.T) {
	t.Parallel()
	hook := newTestHook(t)
	ctx := context.Background()
	id := state.WorkflowID("wf-lifecycle")

	// Start.
	data := json.RawMessage(`{"task": "test"}`)
	wfState, err := hook.OnWorkflowStart(ctx, id, data)
	if err != nil {
		t.Fatalf("OnWorkflowStart: %v", err)
	}
	if wfState == nil {
		t.Fatal("expected non-nil WorkflowState")
	}

	// Step complete.
	stepData := json.RawMessage(`{"result": "ok"}`)
	if err := hook.OnStepComplete(ctx, id, stepData); err != nil {
		t.Fatalf("OnStepComplete: %v", err)
	}

	// Complete.
	if err := hook.OnWorkflowComplete(ctx, id, true); err != nil {
		t.Fatalf("OnWorkflowComplete: %v", err)
	}
}

func TestStateHook_WorkflowLifecycle_Failure(t *testing.T) {
	t.Parallel()
	hook := newTestHook(t)
	ctx := context.Background()
	id := state.WorkflowID("wf-failure")

	_, err := hook.OnWorkflowStart(ctx, id, nil)
	if err != nil {
		t.Fatalf("OnWorkflowStart: %v", err)
	}

	if err := hook.OnWorkflowComplete(ctx, id, false); err != nil {
		t.Fatalf("OnWorkflowComplete(false): %v", err)
	}
}

func TestStateHook_RecoverWorkflow(t *testing.T) {
	t.Parallel()
	hook := newTestHook(t)
	ctx := context.Background()
	id := state.WorkflowID("wf-recover")

	// Start workflow (sets status to running).
	_, err := hook.OnWorkflowStart(ctx, id, json.RawMessage(`{"step": 1}`))
	if err != nil {
		t.Fatalf("OnWorkflowStart: %v", err)
	}

	// Simulate crash: recover without completing.
	recovered, err := hook.RecoverWorkflow(ctx, id)
	if err != nil {
		t.Fatalf("RecoverWorkflow: %v", err)
	}

	// Running workflows should be marked failed on recovery.
	if recovered.Status != state.StatusFailed {
		t.Errorf("Status = %q, want %q", recovered.Status, state.StatusFailed)
	}
}

func TestStateHook_RecoverWorkflow_Completed(t *testing.T) {
	t.Parallel()
	hook := newTestHook(t)
	ctx := context.Background()
	id := state.WorkflowID("wf-recover-completed")

	// Create a completed workflow manually.
	mgr := hook.manager
	wf, err := mgr.CreateWorkflow(id, nil)
	if err != nil {
		t.Fatalf("CreateWorkflow: %v", err)
	}
	wf.Status = state.StatusCompleted
	if err := mgr.SaveCheckpoint(wf); err != nil {
		t.Fatalf("SaveCheckpoint: %v", err)
	}

	// Recovery of a completed workflow should leave it completed.
	recovered, err := hook.RecoverWorkflow(ctx, id)
	if err != nil {
		t.Fatalf("RecoverWorkflow: %v", err)
	}
	if recovered.Status != state.StatusCompleted {
		t.Errorf("Status = %q, want %q", recovered.Status, state.StatusCompleted)
	}
}

func TestStateHook_ListActiveWorkflows(t *testing.T) {
	t.Parallel()
	hook := newTestHook(t)
	ctx := context.Background()

	// Create two workflows.
	for _, id := range []state.WorkflowID{"wf-a", "wf-b"} {
		if _, err := hook.OnWorkflowStart(ctx, id, nil); err != nil {
			t.Fatalf("OnWorkflowStart(%s): %v", id, err)
		}
	}

	ids, err := hook.ListActiveWorkflows()
	if err != nil {
		t.Fatalf("ListActiveWorkflows: %v", err)
	}
	if len(ids) != 2 {
		t.Errorf("got %d active workflows, want 2", len(ids))
	}
}
