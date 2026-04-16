//nolint:testpackage // intentionally uses unexported helpers from main package
package app

import (
	"context"
	"errors"
	"strings"
	"testing"

	"github.com/allthingscode/gobot/internal/config"
	"github.com/allthingscode/gobot/internal/provider"
)

func TestMCPTool_Name(t *testing.T) {
	t.Parallel()
	cfg := config.MCPServerConfig{}
	tool := newMCPTool("my-server", cfg, nil)
	if tool.Name() != "my_server" {
		t.Errorf("got %q, want my_server", tool.Name())
	}
}

func TestMCPTool_Execute_MissingMethod(t *testing.T) {
	t.Parallel()
	cfg := config.MCPServerConfig{}
	tool := newMCPTool("test-srv", cfg, nil)
	_, err := tool.Execute(context.Background(), "session1", "", map[string]any{})
	if err == nil || !strings.Contains(err.Error(), "method is required") {
		t.Errorf("expected missing method error, got: %v", err)
	}
}

type mockMCPCaller struct {
	name string
	resp string
	err  error
}

func (m *mockMCPCaller) start(ctx context.Context) error {
	return nil
}

func (m *mockMCPCaller) Call(ctx context.Context, method string, params any) (string, error) {
	return m.resp, m.err
}

func (m *mockMCPCaller) serverName() string {
	return m.name
}

func TestEnumerateMCPTools(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name      string
		resp      string
		mockErr   error
		wantCount int
		wantErr   bool
		check     func(*testing.T, []*mcpProxyTool)
	}{
		{
			name:      "successful enumeration",
			resp:      `{"result":{"tools":[{"name":"search","description":"search google","inputSchema":{"type":"object"}}]}}`,
			wantCount: 1,
			wantErr:   false,
			check: func(t *testing.T, tools []*mcpProxyTool) {
				t.Helper()
				if tools[0].toolName != "search" {
					t.Errorf("got %q, want search", tools[0].toolName)
				}
				if tools[0].decl.Description != "search google" {
					t.Errorf("got %q, want search google", tools[0].decl.Description)
				}
			},
		},
		{
			name:      "empty tool list",
			resp:      `{"result":{"tools":[]}}`,
			wantCount: 0,
			wantErr:   false,
		},
		{
			name:      "tools/list call failure",
			mockErr:   errors.New("connection closed"),
			wantErr:   true,
		},
		{
			name:      "mcp response error",
			resp:      `{"error":{"code":-32603,"message":"internal error"}}`,
			wantErr:   true,
		},
		{
			name:      "invalid json",
			resp:      `{"result":`,
			wantErr:   true,
		},
	}

	for _, tt := range tests {
		tt := tt
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			caller := &mockMCPCaller{name: "test_server", resp: tt.resp, err: tt.mockErr}
			proxies, err := enumerateMCPTools(context.Background(), caller)
			if (err != nil) != tt.wantErr {
				t.Fatalf("got err %v, wantErr %v", err, tt.wantErr)
			}
			if len(proxies) != tt.wantCount {
				t.Fatalf("got %d tools, want %d", len(proxies), tt.wantCount)
			}
			if tt.check != nil && err == nil {
				tt.check(t, proxies)
			}
		})
	}
}

//nolint:paralleltest // modifies global variable
func TestAppendMCPTools_FallbackAndCollision(t *testing.T) {
	orig := enumerateMCPToolsFunc
	defer func() { enumerateMCPToolsFunc = orig }()

	cfg := &config.Config{
		Tools: config.ToolsConfig{
			MCPServers: map[string]config.MCPServerConfig{
				"server-a": {}, // triggers fallback
				"server-b": {}, // successful
				"server-c": {}, // successful, name collision
			},
		},
	}

	enumerateMCPToolsFunc = func(ctx context.Context, srv mcpCaller) ([]*mcpProxyTool, error) {
		name := srv.serverName()
		if name == "server-a" {
			return nil, errors.New("timeout")
		}
		if name == "server-b" {
			return []*mcpProxyTool{
				{
					server:   srv,
					toolName: "search",
					decl: provider.ToolDeclaration{
						Name:        "search",
						Description: "search tool",
					},
				},
			}, nil
		}
		if name == "server-c" {
			return []*mcpProxyTool{
				{
					server:   srv,
					toolName: "search", // collision with server-b
					decl: provider.ToolDeclaration{
						Name:        "search",
						Description: "another search tool",
					},
				},
			}, nil
		}
		return nil, nil
	}

	// We want to make sure the iteration is predictable or that we check the results irrespective of order
	tools := appendMCPtools(cfg, []Tool{})
	
	// Tools should include: 
	// 1. fallback for server-a (server_a)
	// 2. server-b -> search (or server_b__search if c was processed first)
	// 3. server-c -> search (or server_c__search)
	if len(tools) != 3 {
		t.Fatalf("expected 3 tools, got %d", len(tools))
	}

	toolNames := make(map[string]bool)
	for _, t := range tools {
		toolNames[t.Name()] = true
	}

	if !toolNames["server_a"] {
		t.Errorf("expected fallback tool server_a, got false")
	}

	// Since maps are unordered, either server-b got "search" and server-c got "server_c__search", or vice versa
	if !toolNames["search"] || (!toolNames["server_b__search"] && !toolNames["server_c__search"]) {
		t.Errorf("expected collision resolution, got %v", toolNames)
	}
}

func TestSanitizeMCPToolName(t *testing.T) {
	t.Parallel()
	tests := []struct {
		in   string
		want string
	}{
		{"valid_name_123", "valid_name_123"},
		{"invalid-name", "invalid_name"},
		{"space name", "space_name"},
		{"symbols!@#", "symbols___"},
	}

	for _, tt := range tests {
		tt := tt
		t.Run(tt.in, func(t *testing.T) {
			t.Parallel()
			if got := sanitizeMCPToolName(tt.in); got != tt.want {
				t.Errorf("got %q, want %q", got, tt.want)
			}
		})
	}
}

func TestMcpProxyTool_Execute(t *testing.T) {
	t.Parallel()

	caller := &mockMCPCaller{
		name: "test_server",
		resp: `{"result": "ok"}`,
	}

	tool := &mcpProxyTool{
		server:   caller,
		toolName: "my_action",
		decl: provider.ToolDeclaration{
			Name: "my_action",
		},
	}

	resp, err := tool.Execute(context.Background(), "", "", map[string]any{"arg1": "val1"})
	if err != nil {
		t.Fatalf("Execute failed: %v", err)
	}
	if resp != `{"result": "ok"}` {
		t.Errorf("got %q, want %q", resp, `{"result": "ok"}`)
	}
}
