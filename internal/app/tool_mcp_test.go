//nolint:testpackage // intentionally uses unexported helpers from main package
package app

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"reflect"
	"strings"
	"sync"
	"testing"
	"time"

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
	tools, _ := appendMCPtools(context.Background(), cfg, []Tool{})

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
			tools, _ := appendMCPtools(context.Background(), cfg, nil)
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

const mcpTestBound = 10 * time.Second

func helperMCPServerConfig() config.MCPServerConfig {
	return config.MCPServerConfig{
		Command: os.Args[0],
		Args:    []string{"-test.run=TestMCPServerHelperProcess", "--"},
	}
}

func newHelperMCPServer(t *testing.T, behavior string) *MCPServer {
	t.Helper()
	srv := &MCPServer{
		name: "helper",
		cfg:  helperMCPServerConfig(),
		env:  map[string]string{"GO_WANT_MCP_HELPER": "1", "GO_MCP_BEHAVIOR": behavior},
	}
	t.Cleanup(func() { _ = srv.stop() })
	return srv
}

type mcpCallOutcome struct {
	resp string
	err  error
}

func callAsync(ctx context.Context, srv *MCPServer, method string, params any) <-chan mcpCallOutcome {
	ch := make(chan mcpCallOutcome, 1)
	go func() {
		resp, err := srv.Call(ctx, method, params)
		ch <- mcpCallOutcome{resp: resp, err: err}
	}()
	return ch
}

func awaitOutcome(t *testing.T, ch <-chan mcpCallOutcome, bound time.Duration) mcpCallOutcome {
	t.Helper()
	select {
	case o := <-ch:
		return o
	case <-time.After(bound):
		t.Fatalf("call did not return within %s", bound)
	}
	return mcpCallOutcome{}
}

func waitFor(t *testing.T, what string, cond func() bool) {
	t.Helper()
	deadline := time.Now().Add(mcpTestBound)
	for !cond() {
		if time.Now().After(deadline) {
			t.Fatalf("timed out waiting for %s", what)
		}
		time.Sleep(2 * time.Millisecond)
	}
}

func admissionHeld(srv *MCPServer) bool { return len(srv.admission()) == 1 }

// awaitResponseWait blocks until a request is written and its caller is parked
// waiting for the response: registered as pending with admission released.
func awaitResponseWait(t *testing.T, srv *MCPServer) {
	t.Helper()
	waitFor(t, "caller in response wait", func() bool {
		srv.mu.Lock()
		n := len(srv.pending)
		srv.mu.Unlock()
		return n > 0 && !admissionHeld(srv)
	})
}

// entrySignalWriter closes entered when a Write begins, before it can block.
type entrySignalWriter struct {
	io.WriteCloser
	once    sync.Once
	entered chan struct{}
}

func (w *entrySignalWriter) Write(p []byte) (int, error) {
	w.once.Do(func() { close(w.entered) })
	return w.WriteCloser.Write(p)
}

// wrapStdinWithEntrySignal lets a test cancel only once a write is truly in
// flight, so cancellation cannot win against the pre-write context check.
func wrapStdinWithEntrySignal(srv *MCPServer) <-chan struct{} {
	entered := make(chan struct{})
	srv.mu.Lock()
	srv.stdin = &entrySignalWriter{WriteCloser: srv.stdin, entered: entered}
	srv.mu.Unlock()
	return entered
}

// pipeMCP is an in-process MCP peer built from io.Pipe; the test plays the server.
type pipeMCP struct {
	srv  *MCPServer
	reqs *bufio.Scanner
	out  io.Writer
}

func newPipeMCP(t *testing.T) *pipeMCP {
	t.Helper()
	stdinR, stdinW := io.Pipe()
	stdoutR, stdoutW := io.Pipe()
	srv := &MCPServer{name: "pipe"}
	srv.attach(nil, stdinW, stdoutR)
	t.Cleanup(func() {
		_ = srv.stop()
		_ = stdinR.Close()
		_ = stdoutW.Close()
	})
	sc := bufio.NewScanner(stdinR)
	sc.Buffer(make([]byte, 0, 64*1024), 16*1024*1024)
	return &pipeMCP{srv: srv, reqs: sc, out: stdoutW}
}

func (p *pipeMCP) readRequest(t *testing.T) (id int, tag string) {
	t.Helper()
	if !p.reqs.Scan() {
		t.Fatalf("request stream ended: %v", p.reqs.Err())
	}
	var req struct {
		ID     int `json:"id"`
		Params struct {
			Tag string `json:"tag"`
		} `json:"params"`
	}
	if err := json.Unmarshal(p.reqs.Bytes(), &req); err != nil {
		t.Fatalf("bad request line %q: %v", p.reqs.Text(), err)
	}
	return req.ID, req.Params.Tag
}

func (p *pipeMCP) respond(t *testing.T, id int, tag string) {
	t.Helper()
	line := fmt.Sprintf(`{"jsonrpc":"2.0","id":%d,"result":{"tag":%q}}`+"\n", id, tag)
	if _, err := io.WriteString(p.out, line); err != nil {
		t.Fatalf("respond id %d: %v", id, err)
	}
}

func TestMCPServer_SilentInitializationFailsFinite(t *testing.T) {
	t.Parallel()
	srv := newHelperMCPServer(t, "silent_init")
	srv.handshakeTimeout = 300 * time.Millisecond

	o := awaitOutcome(t, callAsync(context.Background(), srv, "tools/list", nil), mcpTestBound)
	if !errors.Is(o.err, context.DeadlineExceeded) || !strings.Contains(o.err.Error(), "initialize failed") {
		t.Fatalf("want wrapped initialize deadline error, got %v", o.err)
	}
	if srv.cmd != nil || srv.activeReaders.Load() != 0 {
		t.Fatalf("failed start must tear down: cmd=%v readers=%d", srv.cmd, srv.activeReaders.Load())
	}
}

func TestMCPServer_SilentToolsListDiscoveryFailsFinite(t *testing.T) {
	t.Parallel()
	srv := newHelperMCPServer(t, "silent_list")
	if err := srv.start(context.Background()); err != nil {
		t.Fatalf("start: %v", err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 400*time.Millisecond)
	defer cancel()

	type result struct {
		proxies []*mcpProxyTool
		err     error
	}
	ch := make(chan result, 1)
	go func() {
		p, err := enumerateMCPTools(ctx, srv)
		ch <- result{p, err}
	}()
	select {
	case r := <-ch:
		if !errors.Is(r.err, context.DeadlineExceeded) || !strings.Contains(r.err.Error(), "tools/list call failed") {
			t.Fatalf("want wrapped tools/list deadline error, got %v", r.err)
		}
	case <-time.After(mcpTestBound):
		t.Fatal("silent tools/list discovery did not finish")
	}
}

func TestMCPServer_BlockedWriteTearsDownAndReturns(t *testing.T) {
	t.Parallel()
	srv := newHelperMCPServer(t, "stall_after_init")
	if err := srv.start(context.Background()); err != nil {
		t.Fatalf("start: %v", err)
	}
	entered := wrapStdinWithEntrySignal(srv)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	big := strings.Repeat("x", 4*1024*1024)
	ch := callAsync(ctx, srv, "tools/call", map[string]any{"tag": big})
	<-entered
	cancel()
	o := awaitOutcome(t, ch, mcpTestBound)
	if !errors.Is(o.err, context.Canceled) || !strings.Contains(o.err.Error(), "write request") {
		t.Fatalf("want wrapped write cancel error, got %v", o.err)
	}
	if srv.cmd != nil || srv.activeReaders.Load() != 0 || admissionHeld(srv) {
		t.Fatalf("blocked write must tear down: cmd=%v readers=%d held=%v", srv.cmd, srv.activeReaders.Load(), admissionHeld(srv))
	}
}

func TestMCPServer_BlockedPipeWriteCancelled(t *testing.T) {
	t.Parallel()
	p := newPipeMCP(t) // nobody reads the request pipe, so the write blocks
	entered := wrapStdinWithEntrySignal(p.srv)
	ctx, cancel := context.WithCancel(context.Background())
	ch := callAsync(ctx, p.srv, "tools/call", map[string]any{"tag": "w"})
	<-entered
	cancel()
	o := awaitOutcome(t, ch, mcpTestBound)
	if !errors.Is(o.err, context.Canceled) {
		t.Fatalf("want wrapped context.Canceled, got %v", o.err)
	}
	if p.srv.activeReaders.Load() != 0 || admissionHeld(p.srv) {
		t.Fatalf("readers=%d held=%v", p.srv.activeReaders.Load(), admissionHeld(p.srv))
	}
}

func TestMCPServer_CancelWhileQueuedBehindHolder(t *testing.T) {
	t.Parallel()
	srv := newHelperMCPServer(t, "silent_init")
	srv.handshakeTimeout = mcpTestBound

	ctx1, cancel1 := context.WithCancel(context.Background())
	defer cancel1()
	holder := callAsync(ctx1, srv, "tools/list", nil)
	waitFor(t, "holder admitted", func() bool { return admissionHeld(srv) })

	ctx2, cancel2 := context.WithTimeout(context.Background(), 100*time.Millisecond)
	defer cancel2()
	start := time.Now()
	o := awaitOutcome(t, callAsync(ctx2, srv, "tools/list", nil), 3*time.Second)
	if !errors.Is(o.err, context.DeadlineExceeded) || !strings.Contains(o.err.Error(), "waiting for transport") {
		t.Fatalf("want wrapped queued deadline error, got %v", o.err)
	}
	if time.Since(start) > 3*time.Second {
		t.Fatalf("queued caller waited %s", time.Since(start))
	}
	select {
	case <-holder:
		t.Fatal("holder finished before it was cancelled")
	default:
	}

	cancel1()
	o = awaitOutcome(t, holder, mcpTestBound)
	if !errors.Is(o.err, context.Canceled) {
		t.Fatalf("holder: want context.Canceled, got %v", o.err)
	}
}

func TestMCPServer_CancelDuringResponseWait(t *testing.T) {
	t.Parallel()
	srv := newHelperMCPServer(t, "")
	if err := srv.start(context.Background()); err != nil {
		t.Fatalf("start: %v", err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	ch := callAsync(ctx, srv, "tools/call", map[string]any{"tag": "slow", "delay_ms": 30000})
	awaitResponseWait(t, srv)
	cancel()
	o := awaitOutcome(t, ch, mcpTestBound)
	if !errors.Is(o.err, context.Canceled) {
		t.Fatalf("want wrapped context.Canceled, got %v", o.err)
	}
	if srv.activeReaders.Load() != 1 || admissionHeld(srv) {
		t.Fatalf("transport should survive a read-wait cancel: readers=%d", srv.activeReaders.Load())
	}
}

//nolint:gocognit // table rounds interleave cancel, late response and reuse
func TestMCPServer_CancelThenReuseNeverStealsResponse(t *testing.T) {
	t.Parallel()
	for _, lateBeforeNext := range []bool{true, false} {
		t.Run(fmt.Sprintf("lateBeforeNext=%t", lateBeforeNext), func(t *testing.T) {
			t.Parallel()
			p := newPipeMCP(t)
			for i := 0; i < 3; i++ {
				ctx, cancel := context.WithCancel(context.Background())
				stale := callAsync(ctx, p.srv, "tools/call", map[string]any{"tag": "cancelled"})
				staleID, _ := p.readRequest(t)
				waitFor(t, "stale request written", func() bool { return !admissionHeld(p.srv) })
				cancel()
				if o := awaitOutcome(t, stale, mcpTestBound); !errors.Is(o.err, context.Canceled) {
					t.Fatalf("round %d: want context.Canceled, got %v", i, o.err)
				}
				if lateBeforeNext {
					p.respond(t, staleID, "stale")
				}

				fresh := callAsync(context.Background(), p.srv, "tools/call", map[string]any{"tag": "fresh"})
				freshID, _ := p.readRequest(t)
				if !lateBeforeNext {
					p.respond(t, staleID, "stale")
				}
				p.respond(t, freshID, "fresh")
				o := awaitOutcome(t, fresh, mcpTestBound)
				if o.err != nil || !strings.Contains(o.resp, `"fresh"`) || strings.Contains(o.resp, "stale") {
					t.Fatalf("round %d: later call got resp=%q err=%v", i, o.resp, o.err)
				}
			}
			if n := p.srv.activeReaders.Load(); n != 1 {
				t.Fatalf("exactly one reader expected across cancel/reuse, got %d", n)
			}
		})
	}
}

func TestMCPServer_ConcurrentCallersGetOwnResponses(t *testing.T) {
	t.Parallel()
	const callers = 8
	p := newPipeMCP(t)

	p.srv.admission() <- struct{}{} // hold admission so every caller queues
	cancelled, cancelQueued := context.WithCancel(context.Background())
	queuedCancel := callAsync(cancelled, p.srv, "tools/call", map[string]any{"tag": "x"})
	chans := make([]<-chan mcpCallOutcome, callers)
	for i := range chans {
		chans[i] = callAsync(context.Background(), p.srv, "tools/call", map[string]any{"tag": fmt.Sprintf("c%d", i)})
	}
	cancelQueued()
	if o := awaitOutcome(t, queuedCancel, mcpTestBound); !errors.Is(o.err, context.Canceled) {
		t.Fatalf("queued caller: want context.Canceled, got %v", o.err)
	}
	p.srv.release()

	ids := make([]int, callers)
	tags := make([]string, callers)
	for i := 0; i < callers; i++ {
		ids[i], tags[i] = p.readRequest(t)
	}
	for i := callers - 1; i >= 0; i-- {
		p.respond(t, ids[i], tags[i])
	}
	for i, ch := range chans {
		o := awaitOutcome(t, ch, mcpTestBound)
		if o.err != nil {
			t.Fatalf("caller %d: %v", i, o.err)
		}
		want := fmt.Sprintf(`"c%d"`, i)
		if !strings.Contains(o.resp, want) {
			t.Fatalf("caller %d got %q, want tag %s", i, o.resp, want)
		}
	}
}

func TestMCPServer_ResponsesRoutedByIDWithNotifications(t *testing.T) {
	t.Parallel()
	srv := newHelperMCPServer(t, "notify")
	var wg sync.WaitGroup
	for i := 0; i < 4; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			tag := fmt.Sprintf("n%d", i)
			resp, err := srv.Call(context.Background(), "tools/call", map[string]any{"tag": tag, "delay_ms": 20 * (4 - i)})
			if err != nil || !strings.Contains(resp, fmt.Sprintf("%q", tag)) {
				t.Errorf("caller %d got %q err=%v", i, resp, err)
			}
		}(i)
	}
	wg.Wait()
	if n := srv.activeReaders.Load(); n != 1 {
		t.Fatalf("readers=%d", n)
	}
}

func TestMCPServer_RepeatedCancelKeepsSingleReaderAndStopJoins(t *testing.T) {
	t.Parallel()
	srv := newHelperMCPServer(t, "")
	if err := srv.start(context.Background()); err != nil {
		t.Fatal(err)
	}
	for i := 0; i < 5; i++ {
		ctx, cancel := context.WithCancel(context.Background())
		ch := callAsync(ctx, srv, "tools/call", map[string]any{"tag": "late", "delay_ms": 30000})
		awaitResponseWait(t, srv)
		cancel()
		o := awaitOutcome(t, ch, mcpTestBound)
		if !errors.Is(o.err, context.Canceled) {
			t.Fatalf("round %d: %v", i, o.err)
		}
		if n := srv.activeReaders.Load(); n != 1 {
			t.Fatalf("round %d: readers=%d", i, n)
		}
	}
	o := awaitOutcome(t, callAsync(context.Background(), srv, "tools/call", map[string]any{"tag": "final"}), mcpTestBound)
	if o.err != nil || !strings.Contains(o.resp, `"final"`) {
		t.Fatalf("final call: resp=%q err=%v", o.resp, o.err)
	}
	if err := srv.stop(); err != nil {
		t.Fatal(err)
	}
	if n := srv.activeReaders.Load(); n != 0 {
		t.Fatalf("reader not joined by stop: %d", n)
	}
}

//nolint:cyclop // one lifecycle walk: never-started, running, double stop, restart
func TestMCPServer_StopIsIdempotentKillsAndRestarts(t *testing.T) {
	t.Parallel()
	never := &MCPServer{name: "never"}
	if err := never.stop(); err != nil {
		t.Fatal(err)
	}
	if err := never.stop(); err != nil {
		t.Fatal(err)
	}

	srv := newHelperMCPServer(t, "")
	if o := awaitOutcome(t, callAsync(context.Background(), srv, "tools/list", nil), mcpTestBound); o.err != nil {
		t.Fatal(o.err)
	}
	cmd := srv.cmd
	if cmd == nil || cmd.Process == nil {
		t.Fatal("helper process not running")
	}
	for i := 0; i < 2; i++ {
		if err := srv.stop(); err != nil {
			t.Fatal(err)
		}
	}
	if cmd.ProcessState == nil {
		t.Fatal("stop did not wait for the subprocess")
	}
	if srv.activeReaders.Load() != 0 {
		t.Fatal("reader not joined")
	}

	o := awaitOutcome(t, callAsync(context.Background(), srv, "tools/list", nil), mcpTestBound)
	if o.err != nil || srv.lastID != 2 {
		t.Fatalf("restart after stop: err=%v lastID=%d", o.err, srv.lastID)
	}
}

func TestMCPServer_DeadTransportRestartsOnNextCall(t *testing.T) {
	t.Parallel()
	srv := newHelperMCPServer(t, "")
	if o := awaitOutcome(t, callAsync(context.Background(), srv, "tools/list", nil), mcpTestBound); o.err != nil {
		t.Fatal(o.err)
	}
	_ = srv.cmd.Process.Kill()
	waitFor(t, "reader to observe EOF", func() bool { return srv.activeReaders.Load() == 0 })
	o := awaitOutcome(t, callAsync(context.Background(), srv, "tools/call", map[string]any{"tag": "again"}), mcpTestBound)
	if o.err != nil || !strings.Contains(o.resp, `"again"`) {
		t.Fatalf("restart: resp=%q err=%v", o.resp, o.err)
	}
}

//nolint:paralleltest // overrides package timeout and process environment
func TestAppendMCPTools_DiscoveryBoundedAndStopsFailedServer(t *testing.T) {
	t.Setenv("GO_WANT_MCP_HELPER", "1")
	t.Setenv("GO_MCP_BEHAVIOR", "silent_list")
	origTimeout, origFn := mcpDiscoveryTimeout, enumerateMCPToolsFunc
	t.Cleanup(func() { mcpDiscoveryTimeout, enumerateMCPToolsFunc = origTimeout, origFn })
	mcpDiscoveryTimeout = 400 * time.Millisecond

	var started *MCPServer
	enumerateMCPToolsFunc = func(ctx context.Context, srv mcpCaller) ([]*mcpProxyTool, error) {
		started, _ = srv.(*MCPServer)
		// Start outside the short bound so the timeout lands on the silent tools/list.
		if err := srv.start(context.Background()); err != nil {
			return nil, err
		}
		return enumerateMCPTools(ctx, srv)
	}
	cfg := &config.Config{Tools: config.ToolsConfig{MCPServers: map[string]config.MCPServerConfig{"silent": helperMCPServerConfig()}}}
	cfg.Runtime.StorageRoot = t.TempDir()

	begin := time.Now()
	tools, cleanup := appendMCPtools(context.Background(), cfg, nil)
	if time.Since(begin) > mcpTestBound {
		t.Fatalf("discovery took %s", time.Since(begin))
	}
	if len(tools) != 1 {
		t.Fatalf("tools=%#v", tools)
	}
	if _, ok := tools[0].(*mcpTool); !ok || tools[0].Name() != "silent" {
		t.Fatalf("expected passthrough fallback, got %#v", tools[0])
	}
	if started == nil || started.cmd != nil || started.activeReaders.Load() != 0 {
		t.Fatalf("failed enumeration left a running server (captured=%v)", started != nil)
	}
	cleanup()
	cleanup()
}

//nolint:paralleltest // overrides process environment
func TestAppendMCPTools_CleanupStopsServersIdempotently(t *testing.T) {
	t.Setenv("GO_WANT_MCP_HELPER", "1")
	t.Setenv("GO_MCP_BEHAVIOR", "")
	cfg := &config.Config{Tools: config.ToolsConfig{MCPServers: map[string]config.MCPServerConfig{"live": helperMCPServerConfig()}}}
	cfg.Runtime.StorageRoot = t.TempDir()

	tools, cleanup := appendMCPtools(context.Background(), cfg, nil)
	if len(tools) != 1 {
		t.Fatalf("tools=%#v", tools)
	}
	proxy, ok := tools[0].(*mcpProxyTool)
	if !ok {
		t.Fatalf("expected proxy tool, got %#v", tools[0])
	}
	srv, ok := proxy.server.(*MCPServer)
	if !ok || srv.cmd == nil || srv.activeReaders.Load() != 1 {
		t.Fatalf("server should be running after discovery: %#v", proxy.server)
	}
	cmd := srv.cmd
	cleanup()
	cleanup()
	if cmd.ProcessState == nil || srv.cmd != nil || srv.activeReaders.Load() != 0 {
		t.Fatalf("cleanup did not stop and join: state=%v readers=%d", cmd.ProcessState, srv.activeReaders.Load())
	}
}
