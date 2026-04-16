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
			return fmt.Errorf("unmarshal text content: %w", err)
		}
		c.Text = &v
	case "thinking":
		var v ThinkingContent
		if err := json.Unmarshal(data, &v); err != nil {
			return fmt.Errorf("unmarshal thinking content: %w", err)
		}
		c.Thinking = &v
	case "image_url":
		var v ImageContent
		if err := json.Unmarshal(data, &v); err != nil {
			return fmt.Errorf("unmarshal image content: %w", err)
		}
		c.Image = &v
	case "tool_call":
		var v ToolCallContent
		if err := json.Unmarshal(data, &v); err != nil {
			return fmt.Errorf("unmarshal tool call content: %w", err)
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
		b, err := json.Marshal(c.Text)
		if err != nil {
			return nil, fmt.Errorf("marshal text content: %w", err)
		}
		return b, nil
	case c.Thinking != nil:
		b, err := json.Marshal(c.Thinking)
		if err != nil {
			return nil, fmt.Errorf("marshal thinking content: %w", err)
		}
		return b, nil
	case c.Image != nil:
		b, err := json.Marshal(c.Image)
		if err != nil {
			return nil, fmt.Errorf("marshal image content: %w", err)
		}
		return b, nil
	case c.Tool != nil:
		b, err := json.Marshal(c.Tool)
		if err != nil {
			return nil, fmt.Errorf("marshal tool content: %w", err)
		}
		return b, nil
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
		b, err := json.Marshal(*m.Str)
		if err != nil {
			return nil, fmt.Errorf("marshal message content str: %w", err)
		}
		return b, nil
	}
	b, err := json.Marshal(m.Items)
	if err != nil {
		return nil, fmt.Errorf("marshal message content items: %w", err)
	}
	return b, nil
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

// ToolCall represents a single tool invocation requested by the model.
type ToolCall struct {
	ID               string         `json:"id,omitempty"`               // Optional; used by OpenAI/Anthropic for response correlation
	Name             string         `json:"name"`                       // Tool name as declared in ToolDeclaration
	Args             map[string]any `json:"args"`                       // Arguments decoded from the model's response
	ThoughtSignature []byte         `json:"thought_signature,omitempty"` // Gemini-specific: cryptographic signature of the thought block
}

// StrategicMessage is a single entry in the agent conversation history.
// It mirrors the Pydantic StrategicMessage in checkpoint_logic.py.
type StrategicMessage struct {
	Role             MessageRole     `json:"role"`                        // Role (user, assistant, system, etc.).
	Content          *MessageContent `json:"content,omitempty"`           // Text or structured content.
	Name             *string         `json:"name,omitempty"`              // Optional author name (for multi-user/multi-agent).
	ToolCallID       *string         `json:"tool_call_id,omitempty"`      // ID of the tool call this message responds to.
	ToolCalls        []ToolCall      `json:"tool_calls,omitempty"`        // List of tool calls generated (assistant role).
	ReasoningContent *string         `json:"reasoning_content,omitempty"` // Raw internal reasoning from the model.
	ThinkingBlocks   []map[string]any `json:"thinking_blocks,omitempty"`   // Structured internal thinking steps.
	CreatedAt        string          `json:"created_at,omitempty"`        // Timestamp (RFC3339).
}
