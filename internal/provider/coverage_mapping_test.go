//nolint:testpackage // covers provider package internals
package provider

import (
	"context"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	agentctx "github.com/allthingscode/gobot/internal/context"
	"google.golang.org/genai"
)

func ptrString(s string) *string { return &s }

const (
	coverageUserRole  = "user"
	coverageModelRole = "model"
)

func TestGeminiProvider_MapPartsThoughtAndToolSignatures(t *testing.T) {
	t.Parallel()

	p := NewGeminiProvider(&genai.Client{})
	resp := p.mapResponse(&genai.GenerateContentResponse{
		Candidates: []*genai.Candidate{{
			Content: &genai.Content{Parts: []*genai.Part{
				{Text: "first thought", Thought: true, ThoughtSignature: []byte("sig-1")},
				{Text: "second thought", Thought: true, ThoughtSignature: []byte("sig-2")},
				{FunctionCall: &genai.FunctionCall{Name: "lookup", Args: map[string]any{"q": "gobot"}}},
				{Text: "visible"},
			}},
		}},
	})

	if got := *resp.Message.ReasoningContent; got != "first thought\nsecond thought" {
		t.Fatalf("reasoning content = %q", got)
	}
	if len(resp.Message.ThinkingBlocks) != 2 {
		t.Fatalf("thinking blocks = %d, want 2", len(resp.Message.ThinkingBlocks))
	}
	if len(resp.Message.ToolCalls) != 1 || string(resp.Message.ToolCalls[0].ThoughtSignature) != "sig-2" {
		t.Fatalf("tool call did not inherit last thought signature: %#v", resp.Message.ToolCalls)
	}
	if resp.Message.Content == nil || *resp.Message.Content.Str != "visible" {
		t.Fatalf("content = %#v", resp.Message.Content)
	}
}

func TestGeminiProvider_MessagesToContentsCoversParts(t *testing.T) {
	t.Parallel()

	p := NewGeminiProvider(&genai.Client{})
	text := "hello"
	toolName := "search"
	toolID := "call-1"
	contents := p.messagesToContents([]agentctx.StrategicMessage{
		{},
		{
			Role: agentctx.RoleAssistant,
			ThinkingBlocks: []map[string]any{{
				"text":              "reasoning",
				"thought_signature": []byte("sig"),
			}},
			Content: &agentctx.MessageContent{Items: []agentctx.ContentItem{{
				Text: &agentctx.TextContent{Type: "text", Text: text},
			}}},
			ToolCalls: []agentctx.ToolCall{{Name: toolName, Args: map[string]any{"query": "x"}, ThoughtSignature: []byte("tool-sig")}},
		},
		{
			Role:       agentctx.RoleTool,
			Name:       &toolName,
			ToolCallID: &toolID,
			Content:    &agentctx.MessageContent{Str: ptrString(`{"ok":true}`)},
		},
		{
			Role:       agentctx.RoleUser,
			Name:       &toolName,
			ToolCallID: &toolID,
			Content:    &agentctx.MessageContent{Str: ptrString("plain result")},
		},
	})

	if len(contents) != 3 {
		t.Fatalf("contents = %d, want 3", len(contents))
	}
	if contents[0].Role != coverageModelRole || len(contents[0].Parts) != 3 {
		t.Fatalf("assistant content not mapped as expected: %#v", contents[0])
	}
	if contents[1].Role != coverageUserRole || len(contents[1].Parts) == 0 || contents[1].Parts[len(contents[1].Parts)-1].FunctionResponse == nil {
		t.Fatalf("tool result JSON was not mapped: %#v", contents[1])
	}
	lastPart := contents[2].Parts[len(contents[2].Parts)-1]
	if lastPart.FunctionResponse.Response["output"] != "plain result" {
		t.Fatalf("plain tool result fallback not mapped: %#v", lastPart.FunctionResponse.Response)
	}
}

func TestGeminiProvider_BuildConfigFixesNestedSchemaTypes(t *testing.T) {
	t.Parallel()

	p := NewGeminiProvider(&genai.Client{})
	cfg := p.buildConfig(ChatRequest{
		Tools: []ToolDeclaration{{
			Name: "nested",
			Parameters: map[string]any{
				"type": "object",
				"properties": map[string]any{
					"names": map[string]any{
						"type":  "array",
						"items": map[string]any{"type": "string"},
					},
				},
			},
		}},
	})

	schema := cfg.Tools[0].FunctionDeclarations[0].Parameters
	if string(schema.Type) != "OBJECT" {
		t.Fatalf("root type = %q", schema.Type)
	}
	names := schema.Properties["names"]
	if string(names.Type) != "ARRAY" || string(names.Items.Type) != "STRING" {
		t.Fatalf("nested types not normalized: %#v", names)
	}
}

//nolint:cyclop // Covers several internal OpenAI mapping branches without network calls.
func TestOpenAIProvider_InternalMappings(t *testing.T) {
	t.Parallel()

	p := NewOpenRouterProvider("key", "https://example.test/")
	if p.baseURL != "https://example.test" {
		t.Fatalf("base URL not trimmed: %q", p.baseURL)
	}

	textContent := agentctx.MessageContent{Items: []agentctx.ContentItem{
		{Text: &agentctx.TextContent{Type: "text", Text: "one"}},
		{Text: &agentctx.TextContent{Type: "text", Text: "two"}},
	}}
	toolID := "tool-1"
	messages := p.mapMessages([]agentctx.StrategicMessage{
		{Role: agentctx.RoleUser, Content: &textContent},
		{Role: agentctx.RoleAssistant, ToolCalls: []agentctx.ToolCall{{ID: toolID, Name: "do_it", Args: map[string]any{"n": float64(1)}}}},
		{Role: agentctx.RoleTool, ToolCallID: &toolID, Content: &agentctx.MessageContent{Str: ptrString("done")}},
	}, "system prompt")

	if len(messages) != 4 || messages[0].Role != "system" {
		t.Fatalf("messages not mapped with system prompt: %#v", messages)
	}
	if messages[1].Content != "one\ntwo" {
		t.Fatalf("multi-part content = %q", messages[1].Content)
	}
	if len(messages[2].ToolCalls) != 1 || !strings.Contains(messages[2].ToolCalls[0].Function.Arguments, `"n":1`) {
		t.Fatalf("tool calls not mapped: %#v", messages[2].ToolCalls)
	}
	if messages[3].ToolCallID != toolID {
		t.Fatalf("tool call id = %q", messages[3].ToolCallID)
	}

	tools := p.mapTools([]ToolDeclaration{{Name: "tool", Description: "desc", Parameters: map[string]any{"type": "object"}}})
	if len(tools) != 1 || tools[0].Function.Name != "tool" || tools[0].Function.Parameters["type"] != "object" {
		t.Fatalf("tools not mapped: %#v", tools)
	}
	if err := p.parseErrorResponse([]byte(`not-json`), http.StatusTeapot); err == nil || !strings.Contains(err.Error(), "status 418") {
		t.Fatalf("expected fallback error, got %v", err)
	}
}

func TestOpenAIProvider_SendRequestHeaders(t *testing.T) {
	t.Parallel()

	var gotAuth, gotReferer, gotTitle string
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotAuth = r.Header.Get("Authorization")
		gotReferer = r.Header.Get("HTTP-Referer")
		gotTitle = r.Header.Get("X-Title")
		w.WriteHeader(http.StatusOK)
	}))
	defer server.Close()

	p := NewOpenRouterProvider("secret", server.URL)
	resp, err := p.sendRequest(context.Background(), server.URL, []byte(`{}`))
	if err != nil {
		t.Fatalf("sendRequest: %v", err)
	}
	_ = resp.Body.Close()

	if gotAuth != "Bearer secret" || gotReferer == "" || gotTitle != "gobot" {
		t.Fatalf("headers not set: auth=%q referer=%q title=%q", gotAuth, gotReferer, gotTitle)
	}
}

//nolint:cyclop // Covers several internal Anthropic mapping branches without network calls.
func TestAnthropicProvider_InternalMappings(t *testing.T) {
	t.Parallel()

	p := NewAnthropicProvider("key", "")
	toolID := "tool-1"
	messages := p.mapMessages([]agentctx.StrategicMessage{
		{Role: agentctx.RoleUser, Content: &agentctx.MessageContent{Str: ptrString("one")}},
		{Role: agentctx.RoleUser, Content: &agentctx.MessageContent{Items: []agentctx.ContentItem{{Text: &agentctx.TextContent{Type: "text", Text: "two"}}}}},
		{Role: agentctx.RoleAssistant, ToolCalls: []agentctx.ToolCall{{ID: toolID, Name: "lookup", Args: map[string]any{"q": "x"}}}},
		{Role: agentctx.RoleTool, ToolCallID: &toolID, Content: &agentctx.MessageContent{Str: ptrString("result")}},
		{Role: agentctx.RoleAssistant},
	})

	if len(messages) != 3 {
		t.Fatalf("messages = %d, want 3: %#v", len(messages), messages)
	}
	if len(messages[0].Content) != 2 {
		t.Fatalf("consecutive user messages were not merged: %#v", messages[0])
	}
	if messages[1].Content[0].Type != "tool_use" || messages[2].Content[len(messages[2].Content)-1].Type != "tool_result" {
		t.Fatalf("tool blocks not mapped: %#v", messages)
	}
	if _, ok := mapToolResultBlock(agentctx.StrategicMessage{Role: agentctx.RoleTool}); ok {
		t.Fatal("tool result without id should not map")
	}

	tools := p.mapTools([]ToolDeclaration{{Name: "tool", Description: "desc", Parameters: map[string]any{"type": "object"}}})
	if len(tools) != 1 || tools[0].Name != "tool" || tools[0].InputSchema["type"] != "object" {
		t.Fatalf("tools not mapped: %#v", tools)
	}

	resp := p.mapResponse(anthropicResponse{
		Content: []anthropicContentBlock{
			{Type: "text", Text: "a"},
			{Type: "text", Text: "b"},
			{Type: "tool_use", ID: toolID, Name: "lookup", Input: map[string]any{"q": "x"}},
		},
		Usage: anthropicUsage{InputTokens: 2, OutputTokens: 3},
	})
	if resp.Message.Content == nil || *resp.Message.Content.Str != "a\nb" {
		t.Fatalf("text response not joined: %#v", resp.Message.Content)
	}
	if len(resp.Message.ToolCalls) != 1 || resp.Usage.TotalTokens != 5 {
		t.Fatalf("response not mapped: %#v", resp)
	}
}
