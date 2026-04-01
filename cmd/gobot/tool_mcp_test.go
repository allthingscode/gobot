package main

import (
	"context"
	"strings"
	"testing"

	"github.com/allthingscode/gobot/internal/config"
)

func TestMCPTool_Name(t *testing.T) {
	cfg := config.MCPServerConfig{}
	tool := newMCPTool("my-server", cfg, nil)
	if tool.Name() != "my_server" {
		t.Errorf("got %q, want my_server", tool.Name())
	}
}

func TestMCPTool_Execute_MissingMethod(t *testing.T) {
	cfg := config.MCPServerConfig{}
	tool := newMCPTool("test-srv", cfg, nil)
	_, err := tool.Execute(context.Background(), "session1", map[string]any{})
	if err == nil || !strings.Contains(err.Error(), "method is required") {
		t.Errorf("expected missing method error, got: %v", err)
	}
}
