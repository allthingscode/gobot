//nolint:testpackage // intentionally uses unexported helpers from main package
package app

import (
	"testing"

	"github.com/allthingscode/gobot/internal/config"
	"github.com/allthingscode/gobot/internal/memory"
)

func TestBuildSpecialistModels(t *testing.T) {
	t.Parallel()
	cfg := &config.Config{}
	cfg.Agents.Specialists = map[string]config.SpecialistConfig{
		"researcher": {Model: "m1"},
	}
	
	got := buildSpecialistModels(cfg)
	if got["researcher"] != "m1" {
		t.Errorf("expected researcher model m1, got %q", got["researcher"])
	}
}

func TestAppendMemoryTools(t *testing.T) {
	t.Parallel()
	var tools []Tool
	cfg := &config.Config{}
	
	// Case 1: all nil
	got := appendMemoryTools(nil, nil, nil, cfg, tools)
	if len(got) != 0 {
		t.Error("expected zero tools for nil inputs")
	}
}

func TestAppendMemoryTools_Full(t *testing.T) {
	t.Parallel()
	tmpDir := t.TempDir()
	memStore, err := memory.NewMemoryStore(tmpDir)
	if err != nil {
		t.Fatal(err)
	}
	defer func() {
		_ = memStore.Close()
	}()

	var tools []Tool
	cfg := &config.Config{}
	
	got := appendMemoryTools(memStore, nil, nil, cfg, tools)
	if len(got) != 1 {
		t.Errorf("expected 1 tool (search_memory), got %d", len(got))
	}
}

func TestAppendGoogleTools_All(t *testing.T) {
	t.Parallel()
	var tools []Tool
	cfg := &config.Config{}
	cfg.Providers.Google.APIKey = "key"
	cfg.Providers.Google.CustomCX = "cx"
	
	got := appendGoogleTools(cfg, tools)
	// web_search
	if len(got) != 1 {
		t.Errorf("expected 1 tool, got %d", len(got))
	}
}

func TestAppendGmailTools_All(t *testing.T) {
	t.Parallel()
	var tools []Tool
	cfg := &config.Config{}
	cfg.Strategic.UserEmail = "test@example.com"
	cfg.Strategic.GmailReadonly = true
	
	got := appendGmailTools(cfg, "root", tools)
	// send_email, search_gmail, read_gmail
	if len(got) != 3 {
		t.Errorf("expected 3 tools, got %d", len(got))
	}
}

func TestAppendGmailTools_SendOnly(t *testing.T) {
	t.Parallel()
	var tools []Tool
	cfg := &config.Config{}
	cfg.Strategic.UserEmail = "test@example.com"
	cfg.Strategic.GmailReadonly = false
	
	got := appendGmailTools(cfg, "root", tools)
	// send_email only
	if len(got) != 1 {
		t.Errorf("expected 1 tool, got %d", len(got))
	}
}

func TestAppendCalendarTaskTools(t *testing.T) {
	t.Parallel()
	var tools []Tool
	got := appendCalendarTaskTools("root", tools)
	if len(got) != 6 {
		t.Errorf("expected 6 calendar/task tools, got %d", len(got))
	}
}
