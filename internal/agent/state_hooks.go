package agent

import (
	"context"
	"encoding/json"
	"fmt"
	"time"

	"github.com/allthingscode/gobot/internal/state"
)

// StateHook provides checkpoint/restore hooks for subagent workflows.
type StateHook struct {
	manager *state.Manager
}

// NewStateHook creates a new state hook with the given manager.
func NewStateHook(manager *state.Manager) *StateHook {
	return &StateHook{manager: manager}
}

// OnWorkflowStart creates initial checkpoint when workflow starts.
func (h *StateHook) OnWorkflowStart(_ context.Context, id state.WorkflowID, data json.RawMessage) (*state.WorkflowState, error) {
	wfState, err := h.manager.CreateWorkflow(id, data)
	if err != nil {
		return nil, fmt.Errorf("creating workflow state: %w", err)
	}

	// Update to running status.
	if err := h.manager.UpdateStatus(id, state.StatusRunning); err != nil {
		return nil, fmt.Errorf("updating status: %w", err)
	}

	return wfState, nil
}

// OnStepComplete checkpoints after each subagent step completes.
func (h *StateHook) OnStepComplete(_ context.Context, id state.WorkflowID, stepData json.RawMessage) error {
	// Load current state.
	wfState, err := h.manager.LoadWorkflow(id)
	if err != nil {
		return fmt.Errorf("loading workflow: %w", err)
	}

	// Update data with step results.
	wfState.Data = stepData
	wfState.UpdatedAt = time.Now()

	// Save checkpoint.
	if err := h.manager.SaveCheckpoint(wfState); err != nil {
		return fmt.Errorf("saving checkpoint: %w", err)
	}

	return nil
}

// OnWorkflowComplete finalizes workflow and archives.
func (h *StateHook) OnWorkflowComplete(ctx context.Context, id state.WorkflowID, success bool) error {
	status := state.StatusCompleted
	if !success {
		status = state.StatusFailed
	}

	// Update final status.
	if err := h.manager.UpdateStatus(id, status); err != nil {
		return fmt.Errorf("updating final status: %w", err)
	}

	// Archive completed workflow.
	if err := h.manager.Archive(id); err != nil {
		return fmt.Errorf("archiving workflow: %w", err)
	}

	return nil
}

// RecoverWorkflow attempts to recover a crashed workflow.
func (h *StateHook) RecoverWorkflow(ctx context.Context, id state.WorkflowID) (*state.WorkflowState, error) {
	wfState, err := h.manager.LoadWithRecovery(id)
	if err != nil {
		return nil, fmt.Errorf("recovering workflow: %w", err)
	}

	// If workflow was running, mark as failed (crash detected).
	if wfState.Status == state.StatusRunning {
		wfState.Status = state.StatusFailed
		if err := h.manager.SaveCheckpoint(wfState); err != nil {
			return nil, fmt.Errorf("saving recovered state: %w", err)
		}
	}

	return wfState, nil
}

// ListActiveWorkflows returns all active workflow IDs.
func (h *StateHook) ListActiveWorkflows() ([]state.WorkflowID, error) {
	ids, err := h.manager.ListActive()
	if err != nil {
		return nil, fmt.Errorf("list active: %w", err)
	}
	return ids, nil
}
