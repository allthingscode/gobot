// Package context provides durable state persistence for the Strategic Edition
// agent loop. This file contains the message schema types ported from
// checkpoint_logic.py (Pydantic v2 models → plain Go structs with JSON tags).
package context

import (
	"encoding/json"
	"fmt"
	"strings"
)

// ── Content types ─────────────────────────────────────────────────────────────

// TextContent represents a plain-text content item.
type TextContent struct {
	Type string `json:"type"` // always "text"
	Text string `json:"text"`
}

// ThinkingContent represents an internal reasoning/thinking block.
type ThinkingContent struct {
	Type string `json:"type"` // always "thinking"
	Text string `json:"text"`
}

// ImageURL holds the URL of an image content item.
type ImageURL struct {
	URL string `json:"url"`
}

// ImageContent represents an image content item.
type ImageContent struct {
	Type     string   `json:"type"` // always "image_url"
	ImageURL ImageURL `json:"image_url"`
}

// ToolCallFunction holds the name and JSON-encoded arguments of a tool call.
type ToolCallFunction struct {
	Name      string `json:"name"`
	Arguments string `json:"arguments"`
}

// ToolCallContent represents a tool-call content item.
type ToolCallContent struct {
	Type     string           `json:"type"` // always "tool_call"
	ID       string           `json:"id"`
	Function ToolCallFunction `json:"function"`
}

// ── Discriminated-union ContentItem ───────────────────────────────────────────

// ContentItem is a discriminated union of the four content types, keyed on the
// "type" field. Use NewContentItem / ContentItem.Unwrap to work with values.
type ContentItem struct {
	// Exactly one of the following will be non-nil after unmarshalling.
	Text     *TextContent
	Thinking *ThinkingContent
	Image    *ImageContent
	Tool     *ToolCallContent
}

// typeProbe extracts just the "type" discriminator from raw JSON.
type typeProbe struct {
	Type string `json:"type"`
}

// UnmarshalJSON implements json.Unmarshaler for ContentItem.
func (c *ContentItem) unmarshalByType(data []byte, typeName string) error {
	switch typeName {
	case "text":
		var v TextContent
		if err := json.Unmarshal(data, &v); err != nil {
			return err
		}
		c.Text = &v
	case "thinking":
		var v ThinkingContent
		if err := json.Unmarshal(data, &v); err != nil {
			return err
		}
		c.Thinking = &v
	case "image_url":
		var v ImageContent
		if err := json.Unmarshal(data, &v); err != nil {
			return err
		}
		c.Image = &v
	case "tool_call":
		var v ToolCallContent
		if err := json.Unmarshal(data, &v); err != nil {
			return err
		}
		c.Tool = &v
	default:
		return fmt.Errorf("ContentItem: unknown type %q", typeName)
	}
	return nil
}

func (c *ContentItem) UnmarshalJSON(data []byte) error {
	var probe typeProbe
	if err := json.Unmarshal(data, &probe); err != nil {
		return fmt.Errorf("ContentItem: cannot read type field: %w", err)
	}
	return c.unmarshalByType(data, probe.Type)
}

// MarshalJSON implements json.Marshaler for ContentItem.
func (c ContentItem) MarshalJSON() ([]byte, error) {
	switch {
	case c.Text != nil:
		return json.Marshal(c.Text)
	case c.Thinking != nil:
		return json.Marshal(c.Thinking)
	case c.Image != nil:
		return json.Marshal(c.Image)
	case c.Tool != nil:
		return json.Marshal(c.Tool)
	default:
		return nil, fmt.Errorf("ContentItem: all fields are nil")
	}
}

// ── StrategicMessage ──────────────────────────────────────────────────────────

// MessageRole defines the role of a StrategicMessage (e.g., "user", "assistant").
type MessageRole string

const (
	RoleSystem    MessageRole = "system"
	RoleUser      MessageRole = "user"
	RoleAssistant MessageRole = "assistant"
	RoleModel     MessageRole = "model" // Used by Gemini
	RoleTool      MessageRole = "tool"
)

// MessageContent is the union type for the content field of StrategicMessage:
// either a plain string or a list of ContentItems.
type MessageContent struct {
	Str   *string
	Items []ContentItem
}

// UnmarshalJSON handles both string and []ContentItem.
func (m *MessageContent) UnmarshalJSON(data []byte) error {
	// Try string first.
	var s string
	if err := json.Unmarshal(data, &s); err == nil {
		m.Str = &s
		return nil
	}
	// Try array.
	var items []ContentItem
	if err := json.Unmarshal(data, &items); err != nil {
		return fmt.Errorf("MessageContent: expected string or array: %w", err)
	}
	m.Items = items
	return nil
}

// MarshalJSON encodes either the string or the items array.
func (m MessageContent) MarshalJSON() ([]byte, error) {
	if m.Str != nil {
		return json.Marshal(*m.Str)
	}
	return json.Marshal(m.Items)
}

// String returns the text representation of the content.
func (m *MessageContent) String() string {
	if m == nil {
		return ""
	}
	if m.Str != nil {
		return *m.Str
	}
	var sb strings.Builder
	for _, item := range m.Items {
		if item.Text != nil {
			sb.WriteString(item.Text.Text)
		}
	}
	return sb.String()
}

// StrategicMessage is a single entry in the agent conversation history.
// It mirrors the Pydantic StrategicMessage in checkpoint_logic.py.
type StrategicMessage struct {
	Role             MessageRole      `json:"role"`                        // Role (user, assistant, system, etc.).
	Content          *MessageContent  `json:"content,omitempty"`           // Text or structured content.
	Name             *string          `json:"name,omitempty"`              // Optional author name (for multi-user/multi-agent).
	ToolCallID       *string          `json:"tool_call_id,omitempty"`      // ID of the tool call this message responds to.
	ToolCalls        []map[string]any `json:"tool_calls,omitempty"`        // List of tool calls generated (assistant role).
	ReasoningContent *string          `json:"reasoning_content,omitempty"` // Raw internal reasoning from the model.
	ThinkingBlocks   []map[string]any `json:"thinking_blocks,omitempty"`   // Structured internal thinking steps.
	CreatedAt        string           `json:"created_at,omitempty"`        // Timestamp (RFC3339).
}
