// Package provider contains pure provider-layer utilities ported from
// provider_logic.py. No API calls, no I/O.
package provider

import (
	"regexp"
	"strings"
)

// ── Error formatting ──────────────────────────────────────────────────────────

// FormatProviderLog returns the standard provider request log string.
func FormatProviderLog(providerName, model string) string {
	return providerName + " request: model=" + model
}

func containsAny(text string, substrings []string) bool {
	for _, s := range substrings {
		if strings.Contains(text, s) {
			return true
		}
	}
	return false
}

func truncateDetail(detail string, maxLen int) string {
	if len(detail) > maxLen {
		return detail[:maxLen]
	}
	return detail
}

// FormatStrategicError converts common provider errors into human-readable strategic messages.
func FormatStrategicError(errorText string) string {
	if containsAny(errorText, []string{"too many tokens", "context_length", "context window"}) {
		return "[STRATEGIC] Context Overflow (400): The conversation history has exceeded the model's limits. Try a shorter message."
	}

	if containsAny(errorText, []string{"InternalServerError", "500"}) {
		return "[STRATEGIC] Upstream Service Error (500): The AI provider is currently unstable. Please wait a moment and try again."
	}
	if containsAny(errorText, []string{"RateLimitError", "429"}) {
		return "[STRATEGIC] Capacity Limit Reached (429): You have hit the provider's rate limit. Throttling active."
	}
	if containsAny(errorText, []string{"InvalidRequestError", "400"}) {
		detail := truncateDetail(errorText, 100)
		return "[STRATEGIC] Request Denied (400): The provider rejected the payload formatting. Details: " + detail + "..."
	}

	msg := truncateDetail(errorText, 150)
	return "[STRATEGIC] Provider Communication Failure: " + msg
}

// ── Reasoning artifact stripping ──────────────────────────────────────────────

var (
	reThinkTag   = regexp.MustCompile(`(?is)<think>[\s\S]*?</think>`)
	reThoughtTag = regexp.MustCompile(`(?is)<thought>[\s\S]*?</thought>`)

	reMarkdownBold = regexp.MustCompile(
		`(?im)\*\*(Thought|Thoughts|Reasoning|Internal Thought)s?[.:]?\*\*[\s\S]*?(?:\n\n|\z)`,
	)
	reMarkdownItalic = regexp.MustCompile(
		`(?im)\*(Thought|Thoughts|Reasoning|Internal Thought)s?[.:]?\*[\s\S]*?(?:\n\n|\z)`,
	)
	rePlainHeader = regexp.MustCompile(
		`(?im)^(Thought|Thoughts|Reasoning|Internal Thought)s?[.:]?[\s\S]*?(?:\n\n|\z)`,
	)

	reTrailingMarker  = regexp.MustCompile(`(?i)\s+(thought|reasoning)[.:]?$`)
	reOrphanThinkTags = regexp.MustCompile(`(?i)</?(think|thought)>`)
)

// strategicCircuitBreaker is returned when the entire response was reasoning.
const strategicCircuitBreaker = "[STRATEGIC: Your internal reasoning was captured. You MUST now provide a final response to the user or execute a permitted tool call. DO NOT repeat internal thought blocks.]"

// StripReasoningArtifacts aggressively removes reasoning artifacts from a
// model response (<think>, <thought> tags, markdown reasoning headers, etc).
//
// Returns nil when the input is nil or empty. Returns the circuit-breaker
// message when stripping removes 100% of the content and the original
// did not contain "[STRATEGIC]".
func StripReasoningArtifacts(text *string) *string {
	if text == nil || *text == "" {
		return nil
	}
	s := *text

	// 1. Strip <think> / <thought> blocks and their contents.
	s = reThinkTag.ReplaceAllString(s, "")
	s = reThoughtTag.ReplaceAllString(s, "")
	s = strings.TrimSpace(s)

	// 2. Strip markdown bold/italic reasoning headers.
	for _, re := range []*regexp.Regexp{reMarkdownBold, reMarkdownItalic, rePlainHeader} {
		s = re.ReplaceAllString(s, "")
		s = strings.TrimSpace(s)
	}

	// 3. Strip trailing reasoning markers and orphan tags.
	s = reTrailingMarker.ReplaceAllString(s, "")
	s = reOrphanThinkTags.ReplaceAllString(s, "")
	s = strings.TrimSpace(s)

	// 4. Circuit breaker: if stripping removed everything and the original
	//    wasn't already a [STRATEGIC] message, inject the breaker.
	if s == "" && strings.TrimSpace(*text) != "" {
		if strings.Contains(*text, "[STRATEGIC]") {
			return text // preserve original strategic error blocks
		}
		result := strategicCircuitBreaker
		return &result
	}

	if s == "" {
		return nil
	}
	return &s
}
