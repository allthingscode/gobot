package reflection_test

import (
	"strings"
	"testing"

	"github.com/allthingscode/gobot/internal/reflection"
)

// ── GenerateRubricPrompt ──────────────────────────────────────────────────────

func TestGenerateRubricPrompt_ContainsTask(t *testing.T) {
	task := "Write a summary of the quarterly report"
	prompt := reflection.GenerateRubricPrompt(task)
	if !strings.Contains(prompt, task) {
		t.Errorf("rubric prompt does not contain task: %q", task)
	}
}

func TestGenerateRubricPrompt_ContainsSchema(t *testing.T) {
	prompt := reflection.GenerateRubricPrompt("any task")
	if !strings.Contains(prompt, "task_goal") {
		t.Error("rubric prompt should contain 'task_goal' schema field")
	}
	if !strings.Contains(prompt, "success_threshold") {
		t.Error("rubric prompt should contain 'success_threshold' schema field")
	}
}

// ── GenerateCriticPrompt ──────────────────────────────────────────────────────

func TestGenerateCriticPrompt_ContainsAllParts(t *testing.T) {
	task := "Analyze the data"
	rubric := map[string]any{"task_goal": "done", "criteria": []any{}}
	answer := "I analyzed the data and found X."

	prompt := reflection.GenerateCriticPrompt(task, rubric, answer)

	if !strings.Contains(prompt, task) {
		t.Error("critic prompt missing task")
	}
	if !strings.Contains(prompt, answer) {
		t.Error("critic prompt missing proposed answer")
	}
	if !strings.Contains(prompt, "task_goal") {
		t.Error("critic prompt missing rubric JSON")
	}
	if !strings.Contains(prompt, "overall_score") {
		t.Error("critic prompt missing output schema")
	}
}

// ── ParseJSONResponse ─────────────────────────────────────────────────────────

func TestParseJSONResponse_DirectParse(t *testing.T) {
	m, ok := reflection.ParseJSONResponse(`{"key": "value"}`)
	if !ok {
		t.Fatal("expected success for valid JSON")
	}
	if m["key"] != "value" {
		t.Errorf("got %v, want 'value'", m["key"])
	}
}

func TestParseJSONResponse_MarkdownCodeBlock(t *testing.T) {
	input := "Here is the result:\n```json\n{\"score\": 0.9}\n```\nThat's it."
	m, ok := reflection.ParseJSONResponse(input)
	if !ok {
		t.Fatal("expected success parsing JSON from markdown block")
	}
	if m["score"] != 0.9 {
		t.Errorf("got %v, want 0.9", m["score"])
	}
}

func TestParseJSONResponse_LastResortBraces(t *testing.T) {
	input := `The model says: {"passed": true} end of response.`
	m, ok := reflection.ParseJSONResponse(input)
	if !ok {
		t.Fatal("expected success extracting outermost braces")
	}
	if m["passed"] != true {
		t.Errorf("got %v, want true", m["passed"])
	}
}

func TestParseJSONResponse_Empty(t *testing.T) {
	_, ok := reflection.ParseJSONResponse("")
	if ok {
		t.Error("expected failure for empty string")
	}
}

func TestParseJSONResponse_InvalidJSON(t *testing.T) {
	_, ok := reflection.ParseJSONResponse("not json at all")
	if ok {
		t.Error("expected failure for non-JSON text")
	}
}

func TestParseJSONResponse_Whitespace(t *testing.T) {
	_, ok := reflection.ParseJSONResponse("   \n\t  ")
	if ok {
		t.Error("expected failure for whitespace-only input")
	}
}

// ── CalculateTotalScore ───────────────────────────────────────────────────────

func TestCalculateTotalScore_WeightedAverage(t *testing.T) {
	rubric := map[string]any{
		"criteria": []any{
			map[string]any{"name": "A", "weight": 2.0},
			map[string]any{"name": "B", "weight": 1.0},
		},
	}
	report := map[string]any{
		"scores": []any{
			map[string]any{"criterion_name": "A", "score": 1.0},
			map[string]any{"criterion_name": "B", "score": 0.0},
		},
	}
	// Weighted: (1.0*2 + 0.0*1) / 3 = 0.667
	got := reflection.CalculateTotalScore(report, rubric)
	if got < 0.666 || got > 0.668 {
		t.Errorf("got %.3f, want ~0.667", got)
	}
}

func TestCalculateTotalScore_EqualWeights(t *testing.T) {
	rubric := map[string]any{
		"criteria": []any{
			map[string]any{"name": "A", "weight": 1.0},
			map[string]any{"name": "B", "weight": 1.0},
		},
	}
	report := map[string]any{
		"scores": []any{
			map[string]any{"criterion_name": "A", "score": 0.8},
			map[string]any{"criterion_name": "B", "score": 0.6},
		},
	}
	got := reflection.CalculateTotalScore(report, rubric)
	if got != 0.7 {
		t.Errorf("got %.3f, want 0.700", got)
	}
}

func TestCalculateTotalScore_ZeroTotalWeight(t *testing.T) {
	// Empty criteria — denominator is 0, should return 0.0 not panic
	rubric := map[string]any{"criteria": []any{}}
	report := map[string]any{"scores": []any{}}
	got := reflection.CalculateTotalScore(report, rubric)
	if got != 0.0 {
		t.Errorf("got %v, want 0.0 for zero-weight rubric", got)
	}
}

func TestCalculateTotalScore_MissingCriteriaKey(t *testing.T) {
	rubric := map[string]any{}
	report := map[string]any{"scores": []any{}}
	got := reflection.CalculateTotalScore(report, rubric)
	if got != 0.0 {
		t.Errorf("got %v, want 0.0 for missing criteria", got)
	}
}

func TestCalculateTotalScore_MalformedCriterionSkipped(t *testing.T) {
	// A non-map item in criteria should be skipped without panic.
	rubric := map[string]any{
		"criteria": []any{
			"not a map",
			map[string]any{"name": "Valid", "weight": 1.0},
		},
	}
	report := map[string]any{
		"scores": []any{
			map[string]any{"criterion_name": "Valid", "score": 0.8},
		},
	}
	got := reflection.CalculateTotalScore(report, rubric)
	if got != 0.8 {
		t.Errorf("got %.3f, want 0.800", got)
	}
}

func TestCalculateTotalScore_MalformedScoreSkipped(t *testing.T) {
	// A non-map item in scores should be skipped without panic.
	rubric := map[string]any{
		"criteria": []any{
			map[string]any{"name": "A", "weight": 1.0},
		},
	}
	report := map[string]any{
		"scores": []any{
			"not a map",
			map[string]any{"criterion_name": "A", "score": 1.0},
		},
	}
	got := reflection.CalculateTotalScore(report, rubric)
	if got != 1.0 {
		t.Errorf("got %.3f, want 1.000", got)
	}
}

func TestCalculateTotalScore_UnknownCriterionDefaultsTo1(t *testing.T) {
	// Score references a criterion not in the rubric — weight defaults to 1.0
	rubric := map[string]any{
		"criteria": []any{
			map[string]any{"name": "Known", "weight": 1.0},
		},
	}
	report := map[string]any{
		"scores": []any{
			map[string]any{"criterion_name": "Known", "score": 1.0},
			map[string]any{"criterion_name": "Unknown", "score": 0.5},
		},
	}
	// totalWeight = 1.0 (only Known in rubric)
	// weightedSum = 1.0*1.0 + 0.5*1.0 = 1.5 (Unknown falls back to weight 1.0)
	// result = 1.5 / 1.0 = 1.5
	got := reflection.CalculateTotalScore(report, rubric)
	if got != 1.5 {
		t.Errorf("got %.3f, want 1.500", got)
	}
}
