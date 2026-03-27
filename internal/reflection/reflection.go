// Package reflection implements Rubric-Driven Reflection logic (F-031 port).
// All functions are pure — no I/O, no API calls.
package reflection

import (
	"encoding/json"
	"fmt"
	"regexp"
	"strings"
)

// ── Data structures ───────────────────────────────────────────────────────────

type RubricCriterion struct {
	Name        string  `json:"name"`
	Description string  `json:"description"`
	Weight      float64 `json:"weight"`
}

type ValidationRubric struct {
	TaskGoal         string            `json:"task_goal"`
	Criteria         []RubricCriterion `json:"criteria"`
	SuccessThreshold float64           `json:"success_threshold"`
}

type CriticScore struct {
	CriterionName string  `json:"criterion_name"`
	Score         float64 `json:"score"`
	Reasoning     string  `json:"reasoning"`
}

type CriticReport struct {
	OverallScore        float64       `json:"overall_score"`
	Scores              []CriticScore `json:"scores"`
	Passed              bool          `json:"passed"`
	Feedback            string        `json:"feedback"`
	RequiredCorrections []string      `json:"required_corrections"`
}

// ── Prompt generators ─────────────────────────────────────────────────────────

// GenerateRubricPrompt returns the prompt used to ask the model for a JSON
// validation rubric before executing a task.
func GenerateRubricPrompt(task string) string {
	return fmt.Sprintf(`### 🛡️ TASK VALIDATION RUBRIC GENERATION
You are a high-precision architect. Before executing the following task, you must define the measurable criteria for success.

**TASK:** %s

**YOUR JOB:**
Generate a JSON object representing a 'ValidationRubric'.
Identify 3-5 specific, measurable criteria that would prove this task was completed correctly and without hallucinations.

**JSON SCHEMA:**
{
  "task_goal": "A concise summary of the end state",
  "criteria": [
    { "name": "Criterion Name", "description": "How to verify this specifically", "weight": 1.0 }
  ],
  "success_threshold": 0.9
}

**OUTPUT ONLY THE JSON OBJECT.**
`, task)
}

// GenerateCriticPrompt returns the prompt used for the Critic turn to audit
// a specialist's output against a rubric.
func GenerateCriticPrompt(task string, rubric map[string]any, proposedAnswer string) string {
	rubricJSON, _ := json.MarshalIndent(rubric, "", "  ")
	return fmt.Sprintf(`### 🛡️ STRATEGIC CRITIC TURN
You are a high-reasoning auditor. You must evaluate the Specialist's performance against the provided Validation Rubric.

**ORIGINAL TASK:**
%s

**VALIDATION RUBRIC:**
%s

**PROPOSED ANSWER / OUTPUT:**
%s

**YOUR JOB:**
1. Audit the proposed answer against EVERY criterion in the rubric.
2. Be extremely critical. Penalize missing evidence, hallucinations, or "vibes-based" plans instead of execution.
3. Calculate an overall_score (0.0 to 1.0) as a weighted average.
4. Identify 'required_corrections' if any criteria score below 0.8.

**OUTPUT ONLY A JSON OBJECT matching this schema:**
{
  "overall_score": 0.85,
  "scores": [
    { "criterion_name": "Name", "score": 0.7, "reasoning": "Why this score?" }
  ],
  "passed": false,
  "feedback": "Concise summary of quality",
  "required_corrections": ["Specific thing to fix", "Another fix"]
}
`, task, string(rubricJSON), proposedAnswer)
}

// ── JSON extraction ───────────────────────────────────────────────────────────

var (
	reCodeBlock = regexp.MustCompile("(?s)```(?:json)?\\s*([\\s\\S]*?)\\s*```")
	reJSONObj   = regexp.MustCompile(`(?s)(\{[\s\S]*\})`)
)

// ParseJSONResponse robustly extracts and parses a JSON object from a model's
// response. Returns the parsed map and true on success, nil and false otherwise.
//
// Three-tier strategy:
//  1. Direct parse of the full trimmed text.
//  2. Extract from a markdown code block.
//  3. Last-resort: find the outermost {...} in the text.
func ParseJSONResponse(text string) (map[string]any, bool) {
	if strings.TrimSpace(text) == "" {
		return nil, false
	}

	// 1. Direct parse
	var m map[string]any
	if err := json.Unmarshal([]byte(strings.TrimSpace(text)), &m); err == nil {
		return m, true
	}

	// 2. Markdown code block
	if match := reCodeBlock.FindStringSubmatch(text); match != nil {
		if err := json.Unmarshal([]byte(strings.TrimSpace(match[1])), &m); err == nil {
			return m, true
		}
	}

	// 3. Outermost braces
	if match := reJSONObj.FindStringSubmatch(text); match != nil {
		if err := json.Unmarshal([]byte(strings.TrimSpace(match[1])), &m); err == nil {
			return m, true
		}
	}

	return nil, false
}

// ── Score calculation ─────────────────────────────────────────────────────────

// CalculateTotalScore recalculates the weighted total score from a critic
// report, using the weights defined in the rubric. This overrides whatever
// overall_score the model self-reported to prevent score inflation.
//
// Returns 0.0 if the inputs are malformed or weights sum to zero.
func CalculateTotalScore(report, rubric map[string]any) float64 {
	criteriaRaw, _ := rubric["criteria"].([]any)
	weights := make(map[string]float64, len(criteriaRaw))
	totalWeight := 0.0
	for _, c := range criteriaRaw {
		cm, ok := c.(map[string]any)
		if !ok {
			continue
		}
		name, _ := cm["name"].(string)
		weight := 1.0
		if w, ok := cm["weight"].(float64); ok {
			weight = w
		}
		weights[name] = weight
		totalWeight += weight
	}
	if totalWeight == 0 {
		return 0.0
	}

	scoresRaw, _ := report["scores"].([]any)
	weightedSum := 0.0
	for _, s := range scoresRaw {
		sm, ok := s.(map[string]any)
		if !ok {
			continue
		}
		name, _ := sm["criterion_name"].(string)
		score, _ := sm["score"].(float64)
		w := 1.0
		if fw, ok := weights[name]; ok {
			w = fw
		}
		weightedSum += score * w
	}

	result := weightedSum / totalWeight
	// Round to 3 decimal places (matches Python behaviour)
	return float64(int(result*1000+0.5)) / 1000
}
