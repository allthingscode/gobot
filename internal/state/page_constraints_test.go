package state_test

import (
	"path/filepath"
	"testing"

	"github.com/allthingscode/gobot/internal/state"
)

func TestSavePageConstraintSignal(t *testing.T) {
	t.Parallel()

	root := t.TempDir()
	err := state.SavePageConstraintSignal(root, "telegram:123", "auth_required", "login_form")
	if err != nil {
		t.Fatalf("SavePageConstraintSignal failed: %v", err)
	}

	path := filepath.Join(root, "state", "page_constraints", "telegram_123.json")
	var got state.PageConstraintSignal
	if err := state.ReadFileJSON(path, &got); err != nil {
		t.Fatalf("ReadFileJSON failed: %v", err)
	}

	if got.Classification != "auth_required" {
		t.Fatalf("classification = %q, want auth_required", got.Classification)
	}
	if got.LastBlockingSignal != "login_form" {
		t.Fatalf("last signal = %q, want login_form", got.LastBlockingSignal)
	}
}
