package main

import (
	"testing"

	"github.com/allthingscode/gobot/internal/agent"
	agentctx "github.com/allthingscode/gobot/internal/context"
)

func TestExtractText(t *testing.T) {
	s1 := "hello"
	tests := []struct {
		name string
		msg  agentctx.StrategicMessage
		want string
	}{
		{
			name: "single text string",
			msg: agentctx.StrategicMessage{
				Content: &agentctx.MessageContent{Str: &s1},
			},
			want: "hello",
		},
		{
			name: "multiple text items",
			msg: agentctx.StrategicMessage{
				Content: &agentctx.MessageContent{
					Items: []agentctx.ContentItem{
						{Text: &agentctx.TextContent{Text: "hello"}},
						{Text: &agentctx.TextContent{Text: " "}},
						{Text: &agentctx.TextContent{Text: "world"}},
					},
				},
			},
			want: "hello world",
		},
		{
			name: "empty message",
			msg:  agentctx.StrategicMessage{},
			want: "",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := extractText(tt.msg)
			if got != tt.want {
				t.Errorf("extractText() = %q, want %q", got, tt.want)
			}
		})
	}
}

func TestRunner_SetHooks(t *testing.T) {
	r := &geminiRunner{}
	h := &agent.Hooks{}
	r.SetHooks(h)
	if r.hooks != h {
		t.Errorf("SetHooks failed: r.hooks = %v, want %v", r.hooks, h)
	}
}

func TestLastUserText(t *testing.T) {
	s1 := "msg 1"
	s2 := "msg 2"
	messages := []agentctx.StrategicMessage{
		{Role: "user", Content: &agentctx.MessageContent{Str: &s1}},
		{Role: "assistant", Content: &agentctx.MessageContent{Str: &s2}},
	}

	got := lastUserText(messages)
	if got != "msg 1" {
		t.Errorf("lastUserText() = %q, want %q", got, "msg 1")
	}

	s3 := "msg 3"
	messages = append(messages, agentctx.StrategicMessage{Role: "user", Content: &agentctx.MessageContent{Str: &s3}})
	got = lastUserText(messages)
	if got != "msg 3" {
		t.Errorf("lastUserText() = %q, want %q", got, "msg 3")
	}
}
