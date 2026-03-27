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

// FormatStrategicError converts a raw technical error string into a
// user-facing Strategic-format message. The function classifies errors by
// keyword priority before falling back to a generic format.
func FormatStrategicError(errorText string) string {
	// 1. Context window overflow (highest priority)
	for _, kw := range []string{"too many tokens", "context_length", "context window"} {
		if strings.Contains(errorText, kw) {
			return "[STRATEGIC] Context Overflow (400): The conversation history has exceeded the model's limits. Try a shorter message."
		}
	}

	// 2. Status codes and exception types
	if strings.Contains(errorText, "InternalServerError") || strings.Contains(errorText, "500") {
		return "[STRATEGIC] Upstream Service Error (500): The AI provider is currently unstable. Please wait a moment and try again."
	}
	if strings.Contains(errorText, "RateLimitError") || strings.Contains(errorText, "429") {
		return "[STRATEGIC] Capacity Limit Reached (429): You have hit the provider's rate limit. Throttling active."
	}
	if strings.Contains(errorText, "InvalidRequestError") || strings.Contains(errorText, "400") {
		detail := errorText
		if len(detail) > 100 {
			detail = detail[:100]
		}
		return "[STRATEGIC] Request Denied (400): The provider rejected the payload formatting. Details: " + detail + "..."
	}

	// 3. Generic fallback
	msg := errorText
	if len(msg) > 150 {
		msg = msg[:150]
	}
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
	reOrphanThinkTags = regexp.MustCompile(`(?i)<\/?(think|thought)>`)
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
