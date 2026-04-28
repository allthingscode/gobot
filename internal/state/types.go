// Package state provides filesystem-based state management for long-running workflows.
// It implements atomic writes, journaling, and file-based locking for durability.
package state

import (
	"encoding/json"
	"time"
)

// WorkflowID is a unique identifier for a workflow.
type WorkflowID string

// WorkflowStatus represents the current state of a workflow.
type WorkflowStatus string

const (
	// StatusPending indicates the workflow has been created but not started.
	StatusPending WorkflowStatus = "pending"
	// StatusRunning indicates the workflow is currently executing.
	StatusRunning WorkflowStatus = "running"
	// StatusPaused indicates the workflow has been paused and can be resumed.
	StatusPaused WorkflowStatus = "paused"
	// StatusCompleted indicates the workflow finished successfully.
	StatusCompleted WorkflowStatus = "completed"
	// StatusFailed indicates the workflow encountered an error.
	StatusFailed WorkflowStatus = "failed"
)

// WorkflowState represents the persisted state of a workflow.
type WorkflowState struct {
	ID        WorkflowID      `json:"id"`
	Status    WorkflowStatus  `json:"status"`
	Version   int             `json:"version"`
	CreatedAt time.Time       `json:"created_at"`
	UpdatedAt time.Time       `json:"updated_at"`
	Data      json.RawMessage `json:"data,omitempty"`
}

// JournalEntry represents a single operation in the workflow journal.
type JournalEntry struct {
	Timestamp time.Time       `json:"timestamp"`
	Operation string          `json:"operation"`
	Payload   json.RawMessage `json:"payload,omitempty"`
}

// IsTerminal returns true if the workflow has reached a terminal state.
func (s WorkflowStatus) IsTerminal() bool {
	return s == StatusCompleted || s == StatusFailed
}

// IsActive returns true if the workflow is in an active (non-terminal) state.
func (s WorkflowStatus) IsActive() bool {
	return !s.IsTerminal()
}

// WebExtractionPhase represents the current phase of the extraction process.
type WebExtractionPhase string

const (
	PhaseNavigate  WebExtractionPhase = "navigate"
	PhasePlan      WebExtractionPhase = "plan"
	PhaseExtract   WebExtractionPhase = "extract"
	PhaseRetry     WebExtractionPhase = "retry"
	PhaseSummarize WebExtractionPhase = "summarize"
)

// WebExtractionState tracks the progress of a web extraction session.
type WebExtractionState struct {
	SessionID     string             `json:"session_id"`
	URL           string             `json:"url"`
	ActivePhase   WebExtractionPhase `json:"active_phase"`
	LastSelectors []string           `json:"last_selectors"`
	LastError     string             `json:"last_error,omitempty"`
	UpdatedAt     time.Time          `json:"updated_at"`
}
