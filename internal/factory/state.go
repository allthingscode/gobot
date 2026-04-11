package factory

import (
	"time"
)

// SessionState represents the formalized schema for the Dev Factory's session state.
type SessionState struct {
	Version          string                    `json:"version"`           // schema version, e.g., "2.0"
	Timestamp        time.Time                 `json:"timestamp"`         // ISO-8601
	Tasks            map[string]*TaskState     `json:"tasks,omitempty"`   // multi-task support
	LegacySpecialists map[string]*SpecialistState `json:"_legacy,omitempty"` // for backward compatibility
}

// TaskState represents the state of a specific task in the pipeline.
type TaskState struct {
	TaskID           string           `json:"task_id"`
	CurrentPhase     string           `json:"current_phase"` // e.g., "Grooming", "Planning", "Implementation"
	ActiveSpecialist string           `json:"active_specialist"`
	Specialists      SpecialistStates `json:"specialists"` // per-specialist sub-state
}

// SpecialistStates holds the individual states for each specialist role.
type SpecialistStates struct {
	Groomer    *GroomerState    `json:"groomer,omitempty"`
	Architect  *ArchitectState  `json:"architect,omitempty"`
	Reviewer   *ReviewerState   `json:"reviewer,omitempty"`
	Operator   *OperatorState   `json:"operator,omitempty"`
	Researcher *ResearcherState `json:"researcher,omitempty"`
}

// SpecialistState is a generic state for legacy support or simpler tracking.
type SpecialistState struct {
	Phase     string    `json:"phase"`
	Status    string    `json:"status"`
	Notes     string    `json:"notes"`
	Timestamp time.Time `json:"timestamp"`
}

// GroomerState specific to the Groomer role.
type GroomerState struct {
	Phase     string    `json:"phase"` // "Archive Sweep", "Inventory", "Triage", "Specification"
	Status    string    `json:"status"`
	Notes     string    `json:"notes"`
	Timestamp time.Time `json:"timestamp"`
}

// ArchitectState specific to the Architect role.
type ArchitectState struct {
	Phase         string    `json:"phase"` // "Design", "Implementation", "Testing"
	Status        string    `json:"status"`
	Notes         string    `json:"notes"`
	FilesModified []string  `json:"files_modified"`
	TestsPassed   bool      `json:"tests_passed"`
	Timestamp     time.Time `json:"timestamp"`
}

// ReviewerState specific to the Reviewer role.
type ReviewerState struct {
	Phase     string          `json:"phase"`
	Status    string          `json:"status"`
	Notes     string          `json:"notes"`
	Decision  string          `json:"decision"` // "APPROVED", "REJECTED"
	Findings  []ReviewFinding `json:"findings"`
	Timestamp time.Time       `json:"timestamp"`
}

// ReviewFinding represents a single issue found during review.
type ReviewFinding struct {
	Severity    string `json:"severity"` // "BLOCKER", "CRITICAL", "MINOR"
	Description string `json:"description"`
}

// OperatorState specific to the Operator role.
type OperatorState struct {
	Phase              string    `json:"phase"` // "Merging", "Deployment", "Cleanup"
	Status             string    `json:"status"`
	Notes              string    `json:"notes"`
	DeploymentComplete bool      `json:"deployment_complete"`
	Timestamp          time.Time `json:"timestamp"`
}

// ResearcherState specific to the Researcher role.
type ResearcherState struct {
	Phase     string    `json:"phase"`
	Status    string    `json:"status"`
	Notes     string    `json:"notes"`
	Timestamp time.Time `json:"timestamp"`
}
