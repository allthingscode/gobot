package context_test

import (
	"encoding/json"
	"strings"
	"testing"

	ctx "github.com/allthingscode/gobot/internal/context"
)

// ── TextContent ───────────────────────────────────────────────────────────────

func TestTextContent_RoundTrip(t *testing.T) {
	orig := ctx.TextContent{Type: "text", Text: "hello world"}
	data, err := json.Marshal(orig)
	if err != nil {
		t.Fatal(err)
	}
	var got ctx.TextContent
	if err := json.Unmarshal(data, &got); err != nil {
		t.Fatal(err)
	}
	if got.Type != "text" || got.Text != "hello world" {
		t.Errorf("roundtrip mismatch: %+v", got)
	}
}

// ── ThinkingContent ───────────────────────────────────────────────────────────

func TestThinkingContent_RoundTrip(t *testing.T) {
	orig := ctx.ThinkingContent{Type: "thinking", Text: "internal reasoning"}
	data, _ := json.Marshal(orig)
	var got ctx.ThinkingContent
	if err := json.Unmarshal(data, &got); err != nil {
		t.Fatal(err)
	}
	if got.Type != "thinking" || got.Text != "internal reasoning" {
		t.Errorf("roundtrip mismatch: %+v", got)
	}
}

// ── ImageContent ──────────────────────────────────────────────────────────────

func TestImageContent_RoundTrip(t *testing.T) {
	orig := ctx.ImageContent{
		Type:     "image_url",
		ImageURL: ctx.ImageURL{URL: "https://example.com/img.png"},
	}
	data, _ := json.Marshal(orig)
	var got ctx.ImageContent
	if err := json.Unmarshal(data, &got); err != nil {
		t.Fatal(err)
	}
	if got.ImageURL.URL != "https://example.com/img.png" {
		t.Errorf("roundtrip mismatch: %+v", got)
	}
}

// ── ToolCallContent ───────────────────────────────────────────────────────────

func TestToolCallContent_RoundTrip(t *testing.T) {
	orig := ctx.ToolCallContent{
		Type: "tool_call",
		ID:   "call_abc123",
		Function: ctx.ToolCallFunction{
			Name:      "spawn",
			Arguments: `{"role":"researcher"}`,
		},
	}
	data, _ := json.Marshal(orig)
	var got ctx.ToolCallContent
	if err := json.Unmarshal(data, &got); err != nil {
		t.Fatal(err)
	}
	if got.ID != "call_abc123" || got.Function.Name != "spawn" {
		t.Errorf("roundtrip mismatch: %+v", got)
	}
}

// ── ContentItem (discriminated union) ─────────────────────────────────────────

func TestContentItem_UnmarshalText(t *testing.T) {
	raw := `{"type":"text","text":"hi"}`
	var item ctx.ContentItem
	if err := json.Unmarshal([]byte(raw), &item); err != nil {
		t.Fatal(err)
	}
	if item.Text == nil || item.Text.Text != "hi" {
		t.Errorf("expected Text, got %+v", item)
	}
	if item.Thinking != nil || item.Image != nil || item.Tool != nil {
		t.Error("expected only Text to be set")
	}
}

func TestContentItem_UnmarshalThinking(t *testing.T) {
	raw := `{"type":"thinking","text":"reasoning here"}`
	var item ctx.ContentItem
	if err := json.Unmarshal([]byte(raw), &item); err != nil {
		t.Fatal(err)
	}
	if item.Thinking == nil || item.Thinking.Text != "reasoning here" {
		t.Errorf("expected Thinking, got %+v", item)
	}
}

func TestContentItem_UnmarshalImage(t *testing.T) {
	raw := `{"type":"image_url","image_url":{"url":"https://x.com/a.jpg"}}`
	var item ctx.ContentItem
	if err := json.Unmarshal([]byte(raw), &item); err != nil {
		t.Fatal(err)
	}
	if item.Image == nil || item.Image.ImageURL.URL != "https://x.com/a.jpg" {
		t.Errorf("expected Image, got %+v", item)
	}
}

func TestContentItem_UnmarshalToolCall(t *testing.T) {
	raw := `{"type":"tool_call","id":"c1","function":{"name":"spawn","arguments":"{}"}}`
	var item ctx.ContentItem
	if err := json.Unmarshal([]byte(raw), &item); err != nil {
		t.Fatal(err)
	}
	if item.Tool == nil || item.Tool.Function.Name != "spawn" {
		t.Errorf("expected Tool, got %+v", item)
	}
}

func TestContentItem_UnmarshalUnknownType(t *testing.T) {
	raw := `{"type":"video","src":"x.mp4"}`
	var item ctx.ContentItem
	if err := json.Unmarshal([]byte(raw), &item); err == nil {
		t.Error("expected error for unknown type")
	}
}

func TestContentItem_UnmarshalInvalidJSON(t *testing.T) {
	var item ctx.ContentItem
	if err := json.Unmarshal([]byte(`not-json`), &item); err == nil {
		t.Error("expected error for invalid JSON")
	}
}

// Each known type but with malformed body (triggers the inner json.Unmarshal error).
func TestContentItem_UnmarshalMalformedText(t *testing.T) {
	// "text" field is an int, not a string — should fail struct unmarshal.
	raw := `{"type":"text","text":123}`
	var item ctx.ContentItem
	if err := json.Unmarshal([]byte(raw), &item); err == nil {
		t.Error("expected error for malformed TextContent")
	}
}

func TestContentItem_UnmarshalMalformedThinking(t *testing.T) {
	raw := `{"type":"thinking","text":false}`
	var item ctx.ContentItem
	if err := json.Unmarshal([]byte(raw), &item); err == nil {
		t.Error("expected error for malformed ThinkingContent")
	}
}

func TestContentItem_UnmarshalMalformedImage(t *testing.T) {
	raw := `{"type":"image_url","image_url":"not-an-object"}`
	var item ctx.ContentItem
	if err := json.Unmarshal([]byte(raw), &item); err == nil {
		t.Error("expected error for malformed ImageContent")
	}
}

func TestContentItem_UnmarshalMalformedToolCall(t *testing.T) {
	raw := `{"type":"tool_call","id":999}`
	var item ctx.ContentItem
	if err := json.Unmarshal([]byte(raw), &item); err == nil {
		t.Error("expected error for malformed ToolCallContent")
	}
}

func TestContentItem_MarshalText(t *testing.T) {
	item := ctx.ContentItem{Text: &ctx.TextContent{Type: "text", Text: "hello"}}
	data, err := json.Marshal(item)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(data), `"type":"text"`) {
		t.Errorf("unexpected marshal output: %s", data)
	}
}

func TestContentItem_MarshalThinking(t *testing.T) {
	item := ctx.ContentItem{Thinking: &ctx.ThinkingContent{Type: "thinking", Text: "r"}}
	data, err := json.Marshal(item)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(data), `"type":"thinking"`) {
		t.Errorf("unexpected marshal output: %s", data)
	}
}

func TestContentItem_MarshalImage(t *testing.T) {
	item := ctx.ContentItem{Image: &ctx.ImageContent{Type: "image_url", ImageURL: ctx.ImageURL{URL: "u"}}}
	data, err := json.Marshal(item)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(data), `"type":"image_url"`) {
		t.Errorf("unexpected marshal output: %s", data)
	}
}

func TestContentItem_MarshalTool(t *testing.T) {
	item := ctx.ContentItem{Tool: &ctx.ToolCallContent{Type: "tool_call", ID: "x", Function: ctx.ToolCallFunction{Name: "f", Arguments: "{}"}}}
	data, err := json.Marshal(item)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(data), `"type":"tool_call"`) {
		t.Errorf("unexpected marshal output: %s", data)
	}
}

func TestContentItem_MarshalNilAll(t *testing.T) {
	item := ctx.ContentItem{}
	if _, err := json.Marshal(item); err == nil {
		t.Error("expected error marshaling empty ContentItem")
	}
}

func TestContentItem_RoundTrip(t *testing.T) {
	items := []ctx.ContentItem{
		{Text: &ctx.TextContent{Type: "text", Text: "msg"}},
		{Thinking: &ctx.ThinkingContent{Type: "thinking", Text: "reason"}},
		{Tool: &ctx.ToolCallContent{Type: "tool_call", ID: "c2", Function: ctx.ToolCallFunction{Name: "spawn", Arguments: `{"role":"architect"}`}}},
	}
	data, err := json.Marshal(items)
	if err != nil {
		t.Fatal(err)
	}
	var got []ctx.ContentItem
	if err := json.Unmarshal(data, &got); err != nil {
		t.Fatal(err)
	}
	if len(got) != 3 {
		t.Fatalf("expected 3 items, got %d", len(got))
	}
	if got[0].Text == nil || got[0].Text.Text != "msg" {
		t.Errorf("item 0 mismatch: %+v", got[0])
	}
	if got[1].Thinking == nil || got[1].Thinking.Text != "reason" {
		t.Errorf("item 1 mismatch: %+v", got[1])
	}
	if got[2].Tool == nil || got[2].Tool.ID != "c2" {
		t.Errorf("item 2 mismatch: %+v", got[2])
	}
}

// ── MessageContent (string | []ContentItem) ───────────────────────────────────

func TestMessageContent_UnmarshalString(t *testing.T) {
	raw := `"plain text content"`
	var mc ctx.MessageContent
	if err := json.Unmarshal([]byte(raw), &mc); err != nil {
		t.Fatal(err)
	}
	if mc.Str == nil || *mc.Str != "plain text content" {
		t.Errorf("expected string, got %+v", mc)
	}
	if mc.Items != nil {
		t.Error("Items should be nil for string content")
	}
}

func TestMessageContent_UnmarshalItems(t *testing.T) {
	raw := `[{"type":"text","text":"part1"},{"type":"thinking","text":"reason"}]`
	var mc ctx.MessageContent
	if err := json.Unmarshal([]byte(raw), &mc); err != nil {
		t.Fatal(err)
	}
	if mc.Str != nil {
		t.Error("Str should be nil for item-list content")
	}
	if len(mc.Items) != 2 {
		t.Fatalf("expected 2 items, got %d", len(mc.Items))
	}
}

func TestMessageContent_UnmarshalInvalid(t *testing.T) {
	raw := `123`
	var mc ctx.MessageContent
	if err := json.Unmarshal([]byte(raw), &mc); err == nil {
		t.Error("expected error for numeric content")
	}
}

func TestMessageContent_MarshalString(t *testing.T) {
	s := "hello"
	mc := ctx.MessageContent{Str: &s}
	data, err := json.Marshal(mc)
	if err != nil {
		t.Fatal(err)
	}
	if string(data) != `"hello"` {
		t.Errorf("unexpected output: %s", data)
	}
}

func TestMessageContent_MarshalItems(t *testing.T) {
	mc := ctx.MessageContent{
		Items: []ctx.ContentItem{
			{Text: &ctx.TextContent{Type: "text", Text: "x"}},
		},
	}
	data, err := json.Marshal(mc)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(data), `"type":"text"`) {
		t.Errorf("unexpected output: %s", data)
	}
}

func TestMessageContent_MarshalNilStr_NilItems(t *testing.T) {
	// Str=nil, Items=nil → marshals as null array
	mc := ctx.MessageContent{}
	data, err := json.Marshal(mc)
	if err != nil {
		t.Fatal(err)
	}
	if string(data) != "null" {
		t.Errorf("expected null, got %s", data)
	}
}

// ── StrategicMessage ──────────────────────────────────────────────────────────

func TestStrategicMessage_StringContent_RoundTrip(t *testing.T) {
	s := "User message text"
	msg := ctx.StrategicMessage{
		Role:    "user",
		Content: &ctx.MessageContent{Str: &s},
	}
	data, err := json.Marshal(msg)
	if err != nil {
		t.Fatal(err)
	}
	var got ctx.StrategicMessage
	if err := json.Unmarshal(data, &got); err != nil {
		t.Fatal(err)
	}
	if got.Role != "user" {
		t.Errorf("role mismatch: %q", got.Role)
	}
	if got.Content == nil || got.Content.Str == nil || *got.Content.Str != s {
		t.Errorf("content mismatch: %+v", got.Content)
	}
}

func TestStrategicMessage_ItemContent_RoundTrip(t *testing.T) {
	msg := ctx.StrategicMessage{
		Role: "assistant",
		Content: &ctx.MessageContent{
			Items: []ctx.ContentItem{
				{Text: &ctx.TextContent{Type: "text", Text: "answer"}},
				{Thinking: &ctx.ThinkingContent{Type: "thinking", Text: "reasoning"}},
			},
		},
	}
	data, err := json.Marshal(msg)
	if err != nil {
		t.Fatal(err)
	}
	var got ctx.StrategicMessage
	if err := json.Unmarshal(data, &got); err != nil {
		t.Fatal(err)
	}
	if got.Content == nil || len(got.Content.Items) != 2 {
		t.Fatalf("expected 2 items, got %+v", got.Content)
	}
}

func TestStrategicMessage_OptionalFields(t *testing.T) {
	name := "researcher"
	tcid := "tc_001"
	rc := "some reasoning"
	msg := ctx.StrategicMessage{
		Role:             "tool",
		Name:             &name,
		ToolCallID:       &tcid,
		ReasoningContent: &rc,
	}
	data, err := json.Marshal(msg)
	if err != nil {
		t.Fatal(err)
	}
	var got ctx.StrategicMessage
	if err := json.Unmarshal(data, &got); err != nil {
		t.Fatal(err)
	}
	if got.Name == nil || *got.Name != "researcher" {
		t.Errorf("name mismatch: %v", got.Name)
	}
	if got.ToolCallID == nil || *got.ToolCallID != "tc_001" {
		t.Errorf("tool_call_id mismatch: %v", got.ToolCallID)
	}
	if got.ReasoningContent == nil || *got.ReasoningContent != "some reasoning" {
		t.Errorf("reasoning_content mismatch: %v", got.ReasoningContent)
	}
}

func TestStrategicMessage_NilContent_OmitEmpty(t *testing.T) {
	msg := ctx.StrategicMessage{Role: "system"}
	data, err := json.Marshal(msg)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(data), `"content"`) {
		t.Errorf("expected content omitted, got %s", data)
	}
}

func TestStrategicMessage_ToolCalls_RoundTrip(t *testing.T) {
	msg := ctx.StrategicMessage{
		Role: "assistant",
		ToolCalls: []map[string]any{
			{"id": "c1", "type": "function", "function": map[string]any{"name": "spawn", "arguments": "{}"}},
		},
	}
	data, err := json.Marshal(msg)
	if err != nil {
		t.Fatal(err)
	}
	var got ctx.StrategicMessage
	if err := json.Unmarshal(data, &got); err != nil {
		t.Fatal(err)
	}
	if len(got.ToolCalls) != 1 {
		t.Errorf("expected 1 tool call, got %d", len(got.ToolCalls))
	}
}

func TestStrategicMessage_ThinkingBlocks_RoundTrip(t *testing.T) {
	msg := ctx.StrategicMessage{
		Role: "assistant",
		ThinkingBlocks: []map[string]any{
			{"type": "thinking", "thinking": "consider X"},
		},
	}
	data, err := json.Marshal(msg)
	if err != nil {
		t.Fatal(err)
	}
	var got ctx.StrategicMessage
	if err := json.Unmarshal(data, &got); err != nil {
		t.Fatal(err)
	}
	if len(got.ThinkingBlocks) != 1 {
		t.Errorf("expected 1 thinking block, got %d", len(got.ThinkingBlocks))
	}
}

func TestStrategicMessage_Roles(t *testing.T) {
	for _, role := range []string{"system", "user", "assistant", "tool"} {
		msg := ctx.StrategicMessage{Role: role}
		data, _ := json.Marshal(msg)
		var got ctx.StrategicMessage
		if err := json.Unmarshal(data, &got); err != nil {
			t.Errorf("role %q: unmarshal error: %v", role, err)
		}
		if got.Role != role {
			t.Errorf("role %q: got %q", role, got.Role)
		}
	}
}
