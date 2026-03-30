package state

import (
	"testing"
)

func TestWorkflowStatus_IsTerminal(t *testing.T) {
	tests := []struct {
		name string
		status WorkflowStatus
		want   bool
	}{
		{"completed is terminal", StatusCompleted, true},
		{"failed is terminal", StatusFailed, true},
		{"pending is not terminal", StatusPending, false},
		{"running is not terminal", StatusRunning, false},
		{"paused is not terminal", StatusPaused, false},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := tt.status.IsTerminal()
			if got != tt.want {
				t.Errorf("IsTerminal() = %v, want %v", got, tt.want)
			}
		})
	}
}

func TestWorkflowStatus_IsActive(t *testing.T) {
	tests := []struct {
		name string
		status WorkflowStatus
		want   bool
	}{
		{"completed is not active", StatusCompleted, false},
		{"failed is not active", StatusFailed, false},
		{"pending is active", StatusPending, true},
		{"running is active", StatusRunning, true},
		{"paused is active", StatusPaused, true},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := tt.status.IsActive()
			if got != tt.want {
				t.Errorf("IsActive() = %v, want %v", got, tt.want)
			}
		})
	}
}
