package factory

import (
	"encoding/json"
	"testing"
	"time"
)

func TestMigration(t *testing.T) {
	t.Parallel()
	legacyJSON := `{
		"tasks": {
			"F-082": {
				"groomer": {
					"phase": "Complete",
					"notes": "Groomed F-082 Formalized Session State Graph.",
					"status": "idle",
					"timestamp": "2026-04-11T04:12:45Z"
				}
			}
		},
		"_legacy": {
			"specialists": {
				"groomer": {
					"phase": "Complete",
					"status": "legacy-test",
					"notes": "Groomed F-071.",
					"timestamp": "2026-04-11T02:15:55Z"
				}
			}
		}
	}`

	var legacy map[string]interface{}
	if err := json.Unmarshal([]byte(legacyJSON), &legacy); err != nil {
		t.Fatalf("failed to unmarshal legacy: %v", err)
	}

	newState := SessionState{
		Version:   "2.0",
		Timestamp: time.Now().UTC(),
		Tasks:     make(map[string]*TaskState),
	}

	// Logic from migrate command
	if tasksRaw, ok := legacy["tasks"]; ok {
		tasks, _ := tasksRaw.(map[string]interface{})
		for taskID, taskDataRaw := range tasks {
			taskData, _ := taskDataRaw.(map[string]interface{})
			tState := &TaskState{TaskID: taskID}
			for role, roleDataRaw := range taskData {
				roleData, _ := roleDataRaw.(map[string]interface{})
				b, _ := json.Marshal(roleData)
				if role == "groomer" {
					tState.Specialists.Groomer = &GroomerState{}
					if err := json.Unmarshal(b, tState.Specialists.Groomer); err != nil {
						t.Errorf("failed to unmarshal groomer state: %v", err)
					}
				}
			}
			newState.Tasks[taskID] = tState
		}
	}

	if legacyRaw, ok := legacy["_legacy"]; ok {
		legacyMap, _ := legacyRaw.(map[string]interface{})
		if specsRaw, ok := legacyMap["specialists"]; ok {
			specs, _ := specsRaw.(map[string]interface{})
			newState.LegacySpecialists = make(map[string]*SpecialistState)
			for role, roleDataRaw := range specs {
				roleData, _ := roleDataRaw.(map[string]interface{})
				sState := &SpecialistState{}
				b, _ := json.Marshal(roleData)
				if err := json.Unmarshal(b, sState); err != nil {
					t.Errorf("failed to unmarshal legacy state: %v", err)
				}
				newState.LegacySpecialists[role] = sState
			}
		}
	}

	// Verifications
	if newState.Version != "2.0" {
		t.Errorf("expected version 2.0, got %s", newState.Version)
	}

	task, ok := newState.Tasks["F-082"]
	if !ok {
		t.Fatal("task F-082 missing")
	}
	if task.Specialists.Groomer == nil {
		t.Fatal("groomer state missing")
	}
	if task.Specialists.Groomer.Phase != "Complete" {
		t.Errorf("expected phase Complete, got %s", task.Specialists.Groomer.Phase)
	}

	legacyGroomer, ok := newState.LegacySpecialists["groomer"]
	if !ok {
		t.Fatal("legacy groomer missing")
	}
	if legacyGroomer.Status != "legacy-test" {
		t.Errorf("expected status legacy-test, got %s", legacyGroomer.Status)
	}
}
