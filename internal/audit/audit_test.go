package audit_test

import (
	"strings"
	"testing"

	"github.com/allthingscode/gobot/internal/audit"
)

// ── ClassifyModel ─────────────────────────────────────────────────────────────

func TestClassifyModel(t *testing.T) {
	tests := []struct {
		input string
		want  string
	}{
		// Researcher tier
		{"gemini-2.5-flash-lite", "researcher"},
		{"models/gemini-2.5-flash-lite-preview", "researcher"},
		// Default tier
		{"gemini-3-flash-preview", "default"},
		{"models/gemini-2.0-flash", "default"},
		// Architect tier
		{"gemini-3-pro-preview", "architect"},
		{"gemini-ultra", "architect"},
		// Special models
		{"text-embedding-004", "special"},
		{"models/gemini-embedding-001", "special"},
		{"gemini-imagen-3", "special"},
		{"gemma-7b", "special"},
		{"gemini-tts-preview", "special"},
		// Other (no known keyword)
		{"some-unknown-model", "other"},
	}

	for _, tt := range tests {
		t.Run(tt.input, func(t *testing.T) {
			got := audit.ClassifyModel(tt.input)
			if got != tt.want {
				t.Errorf("ClassifyModel(%q) = %q, want %q", tt.input, got, tt.want)
			}
		})
	}
}

func TestClassifyModel_ResearcherBeforeDefault(t *testing.T) {
	// "flash-lite" must be classified as researcher, not default (order test)
	got := audit.ClassifyModel("gemini-flash-lite")
	if got != "researcher" {
		t.Errorf("flash-lite should be researcher, got %q", got)
	}
}

// ── BuildReport ───────────────────────────────────────────────────────────────

func makeModel(name, display, desc string) audit.ModelInfo {
	return audit.ModelInfo{Name: name, DisplayName: display, Description: desc}
}

var current = map[string]string{
	"default":    "gemini-3-flash-preview",
	"researcher": "gemini-2.5-flash-lite",
	"architect":  "gemini-3-pro-preview",
}

func TestBuildReport_ContainsCurrentTag(t *testing.T) {
	models := []audit.ModelInfo{
		makeModel("models/gemini-3-flash-preview", "", ""), // empty DisplayName — exercises fallback
		makeModel("models/gemini-2.5-flash-lite", "Gemini Flash Lite", ""),
		makeModel("models/gemini-3-pro-preview", "Gemini 3 Pro", ""),
	}
	report := audit.BuildReport(models, current)
	if !strings.Contains(report, "**[CURRENT]**") {
		t.Error("report should mark current models with [CURRENT]")
	}
}

func TestBuildReport_SuggestsReplacementForMissingModel(t *testing.T) {
	// default model is NOT in the model list — should produce a suggestion
	models := []audit.ModelInfo{
		makeModel("models/gemini-2.5-flash-lite", "Flash Lite", ""),
		makeModel("models/gemini-3-pro-preview", "Pro", ""),
		makeModel("models/gemini-new-flash", "New Flash", ""), // default tier, but not the current
	}
	report := audit.BuildReport(models, current)
	if !strings.Contains(report, "## Suggested Updates") {
		t.Error("expected Suggested Updates section")
	}
	if strings.Contains(report, "No changes suggested") {
		t.Error("expected a replacement suggestion, not 'No changes suggested'")
	}
}

func TestBuildReport_NoSuggestionWhenCurrentPresent(t *testing.T) {
	models := []audit.ModelInfo{
		makeModel("models/gemini-3-flash-preview", "Flash", ""),
		makeModel("models/gemini-2.5-flash-lite", "Flash Lite", ""),
		makeModel("models/gemini-3-pro-preview", "Pro", ""),
	}
	report := audit.BuildReport(models, current)
	if !strings.Contains(report, "No changes suggested") {
		t.Error("expected 'No changes suggested' when all current models are present")
	}
}

func TestBuildReport_EmptyTierFallback(t *testing.T) {
	// Only provide a researcher model — default and architect tiers will be empty
	models := []audit.ModelInfo{
		makeModel("models/gemini-2.5-flash-lite", "Flash Lite", ""),
	}
	report := audit.BuildReport(models, current)
	if !strings.Contains(report, "*No models classified for this tier.*") {
		t.Error("expected empty-tier fallback message")
	}
}

func TestBuildReport_SpecialModelsSection(t *testing.T) {
	models := []audit.ModelInfo{
		makeModel("models/text-embedding-004", "", ""), // empty DisplayName exercises special-section fallback
		makeModel("models/gemini-3-flash-preview", "Flash", ""),
		makeModel("models/gemini-2.5-flash-lite", "Flash Lite", ""),
		makeModel("models/gemini-3-pro-preview", "Pro", ""),
	}
	report := audit.BuildReport(models, current)
	if !strings.Contains(report, "Special-Purpose") {
		t.Error("expected Special-Purpose section in report")
	}
	if !strings.Contains(report, "text-embedding-004") {
		t.Error("expected embedding model to appear in Special section")
	}
}

func TestBuildReport_DescriptionTruncated(t *testing.T) {
	longDesc := strings.Repeat("x", 200)
	models := []audit.ModelInfo{
		makeModel("models/gemini-3-flash-preview", "Flash", longDesc),
		makeModel("models/gemini-2.5-flash-lite", "Flash Lite", ""),
		makeModel("models/gemini-3-pro-preview", "Pro", ""),
	}
	report := audit.BuildReport(models, current)
	// Description should be truncated to 90 chars
	if strings.Contains(report, strings.Repeat("x", 91)) {
		t.Error("expected description to be truncated to 90 chars")
	}
}

func TestBuildReport_NoModels(t *testing.T) {
	report := audit.BuildReport(nil, current)
	if !strings.Contains(report, "Available models:** 0") {
		t.Error("expected 0 available models count")
	}
}

func TestBuildReport_NoSpecialModels(t *testing.T) {
	// All models are tier-classified — special section should show "*None found.*"
	models := []audit.ModelInfo{
		makeModel("models/gemini-3-flash-preview", "Flash", ""),
		makeModel("models/gemini-2.5-flash-lite", "Flash Lite", ""),
		makeModel("models/gemini-3-pro-preview", "Pro", ""),
	}
	report := audit.BuildReport(models, current)
	if !strings.Contains(report, "*None found.*") {
		t.Error("expected '*None found.*' in special models section when no special models exist")
	}
}
