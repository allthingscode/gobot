package provider_test

import (
	"strings"
	"testing"

	"github.com/allthingscode/gobot/internal/provider"
)

// ── FormatProviderLog ─────────────────────────────────────────────────────────

func TestFormatProviderLog(t *testing.T) {
	t.Parallel()
	got := provider.FormatProviderLog("GoogleGenAI", "gemini-3-flash")
	want := "GoogleGenAI request: model=gemini-3-flash"
	if got != want {
		t.Errorf("got %q, want %q", got, want)
	}
}

// ── FormatStrategicError ──────────────────────────────────────────────────────

func TestFormatStrategicError_ContextOverflow(t *testing.T) {
	t.Parallel()
	tests := []string{"too many tokens", "context_length exceeded", "context window full"}
	for _, input := range tests {
		t.Run(input, func(t *testing.T) {
			t.Parallel()
			got := provider.FormatStrategicError(input)
			if !strings.Contains(got, "Context Overflow (400)") {
				t.Errorf("got %q", got)
			}
		})
	}
}

func TestFormatStrategicError_InternalServerError(t *testing.T) {
	t.Parallel()
	for _, input := range []string{"InternalServerError occurred", "HTTP 500 returned"} {
		got := provider.FormatStrategicError(input)
		if !strings.Contains(got, "Upstream Service Error (500)") {
			t.Errorf("got %q for input %q", got, input)
		}
	}
}

func TestFormatStrategicError_RateLimit(t *testing.T) {
	t.Parallel()
	for _, input := range []string{"RateLimitError", "HTTP 429 Too Many Requests"} {
		got := provider.FormatStrategicError(input)
		if !strings.Contains(got, "Capacity Limit Reached (429)") {
			t.Errorf("got %q for input %q", got, input)
		}
	}
}

func TestFormatStrategicError_InvalidRequest(t *testing.T) {
	t.Parallel()
	for _, input := range []string{"InvalidRequestError", "HTTP 400 Bad Request"} {
		got := provider.FormatStrategicError(input)
		if !strings.Contains(got, "Request Denied (400)") {
			t.Errorf("got %q for input %q", got, input)
		}
	}
}

func TestFormatStrategicError_InvalidRequest_Truncates(t *testing.T) {
	t.Parallel()
	// Detail truncated at 100 chars
	long := "InvalidRequestError: " + strings.Repeat("x", 200)
	got := provider.FormatStrategicError(long)
	if !strings.Contains(got, "Request Denied (400)") {
		t.Errorf("got %q", got)
	}
	// Should not contain more than 100 chars of the detail
	if strings.Contains(got, strings.Repeat("x", 101)) {
		t.Error("expected detail to be truncated to 100 chars")
	}
}

func TestFormatStrategicError_Generic(t *testing.T) {
	t.Parallel()
	got := provider.FormatStrategicError("connection reset by peer")
	if !strings.Contains(got, "Provider Communication Failure") {
		t.Errorf("got %q", got)
	}
}

func TestFormatStrategicError_Generic_Truncates(t *testing.T) {
	t.Parallel()
	long := strings.Repeat("z", 200)
	got := provider.FormatStrategicError(long)
	if strings.Contains(got, strings.Repeat("z", 151)) {
		t.Error("expected generic error to be truncated to 150 chars")
	}
}

// ── StripReasoningArtifacts ───────────────────────────────────────────────────

func strPtr(s string) *string { return &s }

func TestStripReasoningArtifacts_NilInput(t *testing.T) {
	t.Parallel()
	if provider.StripReasoningArtifacts(nil) != nil {
		t.Error("expected nil for nil input")
	}
}

func TestStripReasoningArtifacts_EmptyString(t *testing.T) {
	t.Parallel()
	if provider.StripReasoningArtifacts(strPtr("")) != nil {
		t.Error("expected nil for empty string")
	}
}

func TestStripReasoningArtifacts_WhitespaceOnly(t *testing.T) {
	t.Parallel()
	// Whitespace-only: trims to empty; circuit breaker does NOT fire
	// (TrimSpace of original is also ""), so returns nil via the second nil guard.
	if provider.StripReasoningArtifacts(strPtr("   \n\t  ")) != nil {
		t.Error("expected nil for whitespace-only string")
	}
}

func TestStripReasoningArtifacts_PassthroughCleanText(t *testing.T) {
	t.Parallel()
	input := "The weather in Paris is sunny."
	got := provider.StripReasoningArtifacts(strPtr(input))
	if got == nil || *got != input {
		t.Errorf("expected passthrough, got %v", got)
	}
}

func TestStripReasoningArtifacts_StripsThinkTag(t *testing.T) {
	t.Parallel()
	input := "<think>internal reasoning here</think>Final answer."
	got := provider.StripReasoningArtifacts(strPtr(input))
	if got == nil {
		t.Fatal("expected non-nil result")
	}
	if strings.Contains(*got, "internal reasoning") {
		t.Errorf("expected think tag stripped, got %q", *got)
	}
	if !strings.Contains(*got, "Final answer") {
		t.Errorf("expected final answer preserved, got %q", *got)
	}
}

func TestStripReasoningArtifacts_StripsThoughtTag(t *testing.T) {
	t.Parallel()
	input := "<thought>my reasoning</thought>The result is 42."
	got := provider.StripReasoningArtifacts(strPtr(input))
	if got == nil || strings.Contains(*got, "my reasoning") {
		t.Errorf("expected thought tag stripped, got %v", got)
	}
}

func TestStripReasoningArtifacts_CaseInsensitive(t *testing.T) {
	t.Parallel()
	input := "<THINK>hidden</THINK>visible"
	got := provider.StripReasoningArtifacts(strPtr(input))
	if got == nil || strings.Contains(*got, "hidden") {
		t.Errorf("expected case-insensitive strip, got %v", got)
	}
}

func TestStripReasoningArtifacts_CircuitBreaker(t *testing.T) {
	t.Parallel()
	// Entire response is reasoning — circuit breaker should fire.
	input := "<think>all of this is reasoning</think>"
	got := provider.StripReasoningArtifacts(strPtr(input))
	if got == nil {
		t.Fatal("expected circuit breaker string, got nil")
	}
	if !strings.Contains(*got, "[STRATEGIC") {
		t.Errorf("expected circuit breaker, got %q", *got)
	}
}

func TestStripReasoningArtifacts_PreservesExistingStrategicBlock(t *testing.T) {
	t.Parallel()
	// If the original already contains [STRATEGIC], don't apply circuit breaker.
	input := "<think>reasoning</think>[STRATEGIC] Context Overflow (400): message."
	got := provider.StripReasoningArtifacts(strPtr(input))
	if got == nil {
		t.Fatal("expected non-nil")
	}
	if strings.Contains(*got, "DO NOT repeat") {
		t.Error("circuit breaker should not overwrite existing [STRATEGIC] messages")
	}
}

func TestStripReasoningArtifacts_StripsOrphanClosingTag(t *testing.T) {
	t.Parallel()
	input := "Answer here.</think>"
	got := provider.StripReasoningArtifacts(strPtr(input))
	if got == nil || strings.Contains(*got, "</think>") {
		t.Errorf("expected orphan tag stripped, got %v", got)
	}
}

func TestStripReasoningArtifacts_StripsMarkdownBoldHeader(t *testing.T) {
	t.Parallel()
	input := "**Thoughts:** I should consider X.\n\nActual response here."
	got := provider.StripReasoningArtifacts(strPtr(input))
	if got == nil {
		t.Fatal("expected non-nil")
	}
	if strings.Contains(*got, "I should consider X") {
		t.Errorf("expected bold reasoning header stripped, got %q", *got)
	}
}

func TestStripReasoningArtifacts_StripsMarkdownItalicHeader(t *testing.T) {
	t.Parallel()
	input := "*Reasoning:* internal monologue here\n\nThe answer is 42."
	got := provider.StripReasoningArtifacts(strPtr(input))
	if got == nil {
		t.Fatal("expected non-nil")
	}
	if strings.Contains(*got, "internal monologue") {
		t.Errorf("expected italic reasoning header stripped, got %q", *got)
	}
}

func TestStripReasoningArtifacts_CircuitBreakerPreservesStrategicInsideTag(t *testing.T) {
	t.Parallel()
	// [STRATEGIC] is inside the think tag — after stripping the tag, s is empty.
	// The circuit breaker should fire but preserve the original (contains [STRATEGIC]).
	input := "<think>[STRATEGIC] Context Overflow: the original error.</think>"
	got := provider.StripReasoningArtifacts(strPtr(input))
	if got == nil {
		t.Fatal("expected non-nil result")
	}
	// Should return the original text unchanged (preserves the [STRATEGIC] block).
	if !strings.Contains(*got, "[STRATEGIC]") {
		t.Errorf("expected original [STRATEGIC] block preserved, got %q", *got)
	}
	if strings.Contains(*got, "DO NOT repeat") {
		t.Error("circuit breaker message should not replace [STRATEGIC] content")
	}
}
