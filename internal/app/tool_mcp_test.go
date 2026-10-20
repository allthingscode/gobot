//nolint:testpackage // intentionally uses unexported helpers from main package
package app

import (
	"context"
	"errors"
	"fmt"
	"reflect"
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
			name:    "tools/list call failure",
			mockErr: errors.New("connection closed"),
			wantErr: true,
		},
		{
			name:    "mcp response error",
			resp:    `{"error":{"code":-32603,"message":"internal error"}}`,
			wantErr: true,
		},
		{
			name:    "invalid json",
			resp:    `{"result":`,
			wantErr: true,
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

//nolint:paralleltest // uses global state // modifies global variable
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

type mcpPage struct {
	response string
	err      error
	cancel   bool
}

type scriptedMCPCaller struct {
	t          *testing.T
	pages      []mcpPage
	params     []any
	starts     int
	startErr   error
	cancel     context.CancelFunc
	callParams any
}

func (s *scriptedMCPCaller) serverName() string { return "script-server" }
func (s *scriptedMCPCaller) start(context.Context) error {
	s.starts++
	if s.cancel != nil && len(s.pages) == 0 {
		s.cancel()
	}
	return s.startErr
}
func (s *scriptedMCPCaller) Call(_ context.Context, method string, params any) (string, error) {
	if method == "tools/call" {
		s.callParams = params
		return "scripted tool result", nil
	}
	if method != "tools/list" {
		s.t.Fatalf("unexpected method %q", method)
	}
	i := len(s.params)
	s.params = append(s.params, params)
	if i >= len(s.pages) {
		s.t.Fatalf("unexpected page request %d", i+1)
	}
	page := s.pages[i]
	if page.cancel {
		s.cancel()
	}
	return page.response, page.err
}

//nolint:cyclop // verifies ordered proxies, preserved declarations and forwarded calls together
func TestEnumerateMCPTools_Pages(t *testing.T) {
	t.Parallel()
	const first = `{"result":{"tools":[{"name":"original-name","description":"original description","inputSchema":{"type":"object","required":["query"]}}],"nextCursor":" A /?=+ "}}`
	caller := &scriptedMCPCaller{t: t, pages: []mcpPage{
		{response: first},
		{response: `{"result":{"tools":[],"nextCursor":"B"}}`},
		{response: `{"result":{"tools":[{"name":"second"}],"nextCursor":"C"}}`},
		{response: `{"result":{"tools":[{"name":"third"}]}}`},
	}}
	proxies, err := enumerateMCPTools(context.Background(), caller)
	if err != nil {
		t.Fatal(err)
	}
	if caller.starts != 1 || len(proxies) != 3 {
		t.Fatalf("starts=%d proxies=%d", caller.starts, len(proxies))
	}
	wantParams := []any{nil, map[string]any{"cursor": " A /?=+ "}, map[string]any{"cursor": "B"}, map[string]any{"cursor": "C"}}
	if !reflect.DeepEqual(caller.params, wantParams) {
		t.Fatalf("params=%#v", caller.params)
	}
	for i, name := range []string{"original-name", "second", "third"} {
		if proxies[i].Name() != name || proxies[i].toolName != name || proxies[i].server != caller {
			t.Fatalf("proxy %d=%#v", i, proxies[i])
		}
	}
	decl := proxies[0].Declaration()
	if decl.Description != "original description" || !reflect.DeepEqual(decl.Parameters, map[string]any{"type": "object", "required": []any{"query"}}) {
		t.Fatalf("declaration=%#v", decl)
	}
	args := map[string]any{"query": "value"}
	resp, err := proxies[0].Execute(context.Background(), "", "", args)
	if err != nil || resp != "scripted tool result" || !reflect.DeepEqual(caller.callParams, map[string]any{"name": "original-name", "arguments": args}) {
		t.Fatalf("call params=%#v response=%q error=%v", caller.callParams, resp, err)
	}
}

//nolint:gocognit // table keeps all failure and cancellation contracts visible together
func TestEnumerateMCPTools_FailuresAndCancellation(t *testing.T) {
	t.Parallel()
	transportErr := errors.New("transport lost")
	const pageA = `{"result":{"tools":[{"name":"partial"}],"nextCursor":"A"}}`
	const pageB = `{"result":{"tools":[],"nextCursor":"B"}}`
	tests := []struct {
		name      string
		pages     []mcpPage
		preCancel bool
		startErr  error
		wantErr   error
		wantText  string
		calls     int
		starts    int
	}{
		{name: "repeated cursor", pages: []mcpPage{{response: pageA}, {response: pageA}}, wantText: "repeated", calls: 2, starts: 1},
		{name: "alternating cycle", pages: []mcpPage{{response: pageA}, {response: pageB}, {response: pageA}}, wantText: "repeated", calls: 3, starts: 1},
		{name: "later transport", pages: []mcpPage{{response: pageA}, {err: transportErr}}, wantErr: transportErr, wantText: "tools/list call", calls: 2, starts: 1},
		{name: "later malformed", pages: []mcpPage{{response: pageA}, {response: `{"result":`}}, wantText: "parse tools/list", calls: 2, starts: 1},
		{name: "later RPC error", pages: []mcpPage{{response: pageA}, {response: `{"error":{"code":-1,"message":"failed"}}`}}, wantText: "code -1, message failed", calls: 2, starts: 1},
		{name: "invalid cursor type", pages: []mcpPage{{response: pageA}, {response: `{"result":{"nextCursor":42}}`}}, wantText: "parse tools/list", calls: 2, starts: 1},
		{name: "pre canceled", preCancel: true, wantErr: context.Canceled, wantText: "before start"},
		{name: "between pages", pages: []mcpPage{{response: pageA, cancel: true}}, wantErr: context.Canceled, wantText: "after response", calls: 1, starts: 1},
		{name: "terminal response canceled", pages: []mcpPage{{response: `{"result":{"tools":[]}}`, cancel: true}}, wantErr: context.Canceled, wantText: "after response", calls: 1, starts: 1},
		{name: "page call canceled", pages: []mcpPage{{response: pageA}, {err: context.Canceled}}, wantErr: context.Canceled, wantText: "tools/list call", calls: 2, starts: 1},
		{name: "page deadline", pages: []mcpPage{{response: pageA}, {err: context.DeadlineExceeded}}, wantErr: context.DeadlineExceeded, wantText: "tools/list call", calls: 2, starts: 1},
		{name: "canceled after start", wantErr: context.Canceled, wantText: "before request", starts: 1},
		{name: "start failed", startErr: transportErr, wantErr: transportErr, wantText: "start server", starts: 1},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			if tt.preCancel {
				cancel()
			}
			caller := &scriptedMCPCaller{t: t, pages: tt.pages, cancel: cancel, startErr: tt.startErr}
			proxies, err := enumerateMCPTools(ctx, caller)
			if err == nil || proxies != nil || !strings.Contains(err.Error(), tt.wantText) {
				t.Fatalf("proxies=%#v error=%v", proxies, err)
			}
			if tt.wantErr != nil && !errors.Is(err, tt.wantErr) {
				t.Fatalf("error %v does not wrap %v", err, tt.wantErr)
			}
			if len(caller.params) != tt.calls || caller.starts != tt.starts {
				t.Fatalf("calls=%d starts=%d", len(caller.params), caller.starts)
			}
		})
	}
}

//nolint:paralleltest,gocognit,cyclop // global hook requires serial registration assertions for success and fallback
func TestAppendMCPTools_PaginatedEnumeration(t *testing.T) {
	original := enumerateMCPToolsFunc
	t.Cleanup(func() { enumerateMCPToolsFunc = original })
	for _, fail := range []bool{false, true} {
		t.Run(fmt.Sprintf("failure=%t", fail), func(t *testing.T) {
			caller := &scriptedMCPCaller{t: t, pages: []mcpPage{
				{response: `{"result":{"tools":[{"name":"same-name"}],"nextCursor":"next"}}`},
				{response: `{"result":{"tools":[{"name":"same name"},{"name":"last"}]}}`},
			}}
			if fail {
				caller.pages[1].err = errors.New("page unavailable")
			}
			enumerateMCPToolsFunc = func(ctx context.Context, _ mcpCaller) ([]*mcpProxyTool, error) { return enumerateMCPTools(ctx, caller) }
			cfg := &config.Config{Tools: config.ToolsConfig{MCPServers: map[string]config.MCPServerConfig{"script-server": {}}}}
			tools := appendMCPtools(cfg, nil)
			if len(caller.params) != 2 {
				t.Fatalf("page requests=%d", len(caller.params))
			}
			if fail {
				if len(tools) != 1 {
					t.Fatalf("tools=%#v", tools)
				}
				if _, ok := tools[0].(*mcpTool); !ok || tools[0].Name() != "script_server" {
					t.Fatalf("fallback=%#v", tools[0])
				}
				return
			}
			if len(tools) != 3 {
				t.Fatalf("tools=%#v", tools)
			}
			for i, name := range []string{"same_name", "script_server__same_name", "last"} {
				proxy, ok := tools[i].(*mcpProxyTool)
				if !ok || proxy.Name() != name || proxy.server != caller {
					t.Fatalf("tool %d=%#v", i, tools[i])
				}
			}
		})
	}
}

func TestEnumerateMCPTools_EmptyTerminalPage(t *testing.T) {
	t.Parallel()
	for _, terminal := range []string{`{"result":{"tools":[]}}`, `{"result":{"tools":[],"nextCursor":""}}`} {
		t.Run(terminal, func(t *testing.T) {
			t.Parallel()
			caller := &scriptedMCPCaller{t: t, pages: []mcpPage{
				{response: `{"result":{"tools":[{"name":"retained"}],"nextCursor":"next"}}`},
				{response: terminal},
			}}
			proxies, err := enumerateMCPTools(context.Background(), caller)
			if err != nil || len(proxies) != 1 || proxies[0].Name() != "retained" || len(caller.params) != 2 {
				t.Fatalf("proxies=%#v calls=%d error=%v", proxies, len(caller.params), err)
			}
		})
	}
}
