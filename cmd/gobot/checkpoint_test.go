package main

import (
	"testing"

	agentctx "github.com/allthingscode/gobot/internal/context"
)

func TestExtractMessageText(t *testing.T) {
	t.Parallel()
	
	// Case 1: nil content
	if got := extractMessageText(agentctx.StrategicMessage{Content: nil}); got != "(no content)" {
		t.Errorf("got %q, want '(no content)'", got)
	}

	// Case 2: Str content
	msg := "hello"
	if got := extractMessageText(agentctx.StrategicMessage{Content: &agentctx.MessageContent{Str: &msg}}); got != "hello" {
		t.Errorf("got %q, want 'hello'", got)
	}

	// Case 3: Item content
	item := agentctx.ContentItem{Text: &agentctx.TextContent{Text: "world"}}
	if got := extractMessageText(agentctx.StrategicMessage{Content: &agentctx.MessageContent{Items: []agentctx.ContentItem{item}}}); got != "world" {
		t.Errorf("got %q, want 'world'", got)
	}
}
