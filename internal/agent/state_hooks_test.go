package agent

import (
	"context"
	"encoding/json"
	"testing"
	"time"

	"github.com/allthingscode/gobot/internal/state"
)

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
