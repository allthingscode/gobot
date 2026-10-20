package app

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"os"
	"os/exec"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/allthingscode/gobot/internal/agent"
	"github.com/allthingscode/gobot/internal/config"
	"github.com/allthingscode/gobot/internal/provider"
)

// Package defaults for MCP lifetimes; internal constants, overridable in tests.
//
//nolint:gochecknoglobals // test-overridable defaults
var (
	mcpHandshakeTimeout = 30 * time.Second
	mcpDiscoveryTimeout = 60 * time.Second
)

const mcpMaxTokenSize = 10 * 1024 * 1024 // 10MB buffer for large git/filesystem outputs

type mcpResult struct {
	line string
	err  error
}

type mcpRequest struct {
	id   int
	ch   chan mcpResult
	done <-chan struct{}
}

// syncBuffer is a bytes.Buffer safe for the exec stderr copier and readers.
type syncBuffer struct {
	mu  sync.Mutex
	buf bytes.Buffer
}

func (b *syncBuffer) Write(p []byte) (int, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	n, _ := b.buf.Write(p) // bytes.Buffer.Write never fails
	return n, nil
}

func (b *syncBuffer) String() string {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.buf.String()
}

func (b *syncBuffer) Reset() {
	b.mu.Lock()
	defer b.mu.Unlock()
	b.buf.Reset()
}

// MCPServer manages a persistent MCP subprocess. Exactly one reader goroutine
// owns the subprocess stdout per transport generation and routes each response
// to the waiting request by id.
type MCPServer struct {
	name string
	cfg  config.MCPServerConfig
	env  map[string]string

	// handshakeTimeout bounds initialization; zero uses mcpHandshakeTimeout.
	handshakeTimeout time.Duration

	// admission serialises start and request writes; waiters honour ctx.
	admitOnce sync.Once
	admit     chan struct{}
	// stopMu serialises teardown so a second caller waits for the first.
	stopMu sync.Mutex

	// mu guards the fields below and is only ever held briefly.
	mu          sync.Mutex
	cmd         *exec.Cmd
	stdin       io.WriteCloser
	stdout      io.ReadCloser
	stderr      syncBuffer
	pending     map[int]chan mcpResult
	readerDone  chan struct{}
	dead        bool
	initialized bool
	lastID      int

	activeReaders atomic.Int32
}

func (s *MCPServer) admission() chan struct{} {
	s.admitOnce.Do(func() { s.admit = make(chan struct{}, 1) })
	return s.admit
}

func (s *MCPServer) acquire(ctx context.Context) error {
	if err := ctx.Err(); err != nil {
		return fmt.Errorf("admission: %w", err)
	}
	select {
	case s.admission() <- struct{}{}:
		return nil
	case <-ctx.Done():
		return fmt.Errorf("admission: %w", ctx.Err())
	}
}

func (s *MCPServer) release() { <-s.admission() }

func (s *MCPServer) handshakeBound() time.Duration {
	if s.handshakeTimeout > 0 {
		return s.handshakeTimeout
	}
	return mcpHandshakeTimeout
}

func (s *MCPServer) start(ctx context.Context) error {
	if err := s.acquire(ctx); err != nil {
		return fmt.Errorf("mcp %s: waiting for transport: %w", s.name, err)
	}
	defer s.release()
	return s.ensureStarted(ctx)
}

// ensureStarted must be called with admission held.
func (s *MCPServer) ensureStarted(ctx context.Context) error {
	s.mu.Lock()
	running := s.stdin != nil && !s.dead
	s.mu.Unlock()
	if running {
		return nil
	}
	s.teardown()
	return s.startProcess(ctx)
}

func (s *MCPServer) startProcess(ctx context.Context) error {
	// The subprocess outlives any single request, so it is not bound to ctx.
	// #nosec G204
	//nolint:noctx // lifetime is owned by stop(), not by any request context
	cmd := exec.Command(s.cfg.Command, s.cfg.Args...)
	cmd.Env = os.Environ()
	for k, v := range s.env {
		cmd.Env = append(cmd.Env, fmt.Sprintf("%s=%s", k, v))
	}

	stdin, err := cmd.StdinPipe()
	if err != nil {
		return fmt.Errorf("mcp %s: stdin pipe: %w", s.name, err)
	}
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		_ = stdin.Close()
		return fmt.Errorf("mcp %s: stdout pipe: %w", s.name, err)
	}
	s.stderr.Reset()
	cmd.Stderr = &s.stderr

	if err := cmd.Start(); err != nil {
		return fmt.Errorf("mcp start %s: %w", s.name, err)
	}
	s.attach(cmd, stdin, stdout)

	hctx, cancel := context.WithTimeout(ctx, s.handshakeBound())
	defer cancel()
	if err := s.handshake(hctx); err != nil {
		s.teardown()
		return fmt.Errorf("mcp %s: %w, stderr: %s", s.name, err, s.stderr.String())
	}

	s.mu.Lock()
	s.initialized = true
	s.mu.Unlock()
	return nil
}

// attach installs a transport generation and launches its single reader.
func (s *MCPServer) attach(cmd *exec.Cmd, stdin io.WriteCloser, stdout io.ReadCloser) {
	done := make(chan struct{})
	s.mu.Lock()
	s.cmd = cmd
	s.stdin = stdin
	s.stdout = stdout
	s.pending = make(map[int]chan mcpResult)
	s.readerDone = done
	s.dead = false
	s.initialized = false
	s.lastID = 0
	s.activeReaders.Add(1)
	s.mu.Unlock()
	go s.readLoop(stdout, done)
}

func (s *MCPServer) readLoop(stdout io.Reader, done chan struct{}) {
	scanner := bufio.NewScanner(stdout)
	scanner.Buffer(make([]byte, 0, 64*1024), mcpMaxTokenSize)
	for scanner.Scan() {
		line := scanner.Text()
		if line == "" {
			continue
		}
		var peek struct {
			ID     *int   `json:"id"`
			Method string `json:"method"`
		}
		// Notifications and server-initiated requests are not responses to us.
		if err := json.Unmarshal([]byte(line), &peek); err != nil || peek.ID == nil || peek.Method != "" {
			slog.Debug("mcp: ignoring line", "server", s.name)
			continue
		}
		s.route(*peek.ID, line)
	}
	cause := error(io.EOF)
	if err := scanner.Err(); err != nil {
		cause = fmt.Errorf("scan error: %w", err)
	}
	s.finishReader(done, cause)
}

func (s *MCPServer) route(id int, line string) {
	s.mu.Lock()
	ch, ok := s.pending[id]
	if ok {
		delete(s.pending, id)
	}
	s.mu.Unlock()
	if !ok {
		slog.Debug("mcp: dropping unmatched response", "server", s.name, "id", id)
		return
	}
	ch <- mcpResult{line: line} // capacity 1, one send per registration
}

func (s *MCPServer) finishReader(done chan struct{}, cause error) {
	s.mu.Lock()
	if s.readerDone == done {
		s.dead = true
	}
	for id, ch := range s.pending {
		select {
		case ch <- mcpResult{err: fmt.Errorf("mcp %s: %w before response id %d", s.name, cause, id)}:
		default:
		}
	}
	s.mu.Unlock()
	s.activeReaders.Add(-1)
	close(done)
}

func (s *MCPServer) deregister(id int) {
	s.mu.Lock()
	delete(s.pending, id)
	s.mu.Unlock()
}

// stop terminates the subprocess and joins its reader. It is idempotent.
func (s *MCPServer) stop() error {
	s.teardown()
	return nil
}

func (s *MCPServer) teardown() {
	s.stopMu.Lock()
	defer s.stopMu.Unlock()

	s.mu.Lock()
	cmd, stdin, stdout, done := s.cmd, s.stdin, s.stdout, s.readerDone
	s.cmd, s.stdin, s.stdout, s.readerDone, s.pending = nil, nil, nil, nil, nil
	s.dead = false
	s.initialized = false
	s.mu.Unlock()

	if cmd != nil && cmd.Process != nil {
		_ = cmd.Process.Kill()
	}
	if stdin != nil {
		_ = stdin.Close()
	}
	if stdout != nil {
		_ = stdout.Close()
	}
	if done != nil {
		<-done
	}
	if cmd != nil {
		_ = cmd.Wait()
	}
}

func (s *MCPServer) handshake(ctx context.Context) error {
	req, err := s.send(ctx, "initialize", map[string]any{
		"protocolVersion": "2024-11-05",
		"capabilities":    map[string]any{},
		"clientInfo": map[string]any{
			"name":    "gobot",
			"version": "1.0.0",
		},
	})
	if err != nil {
		return fmt.Errorf("initialize failed: %w", err)
	}
	defer s.deregister(req.id)
	if _, err := s.await(ctx, req); err != nil {
		return fmt.Errorf("initialize failed: %w", err)
	}

	nb, _ := json.Marshal(map[string]any{
		"jsonrpc": "2.0",
		"method":  "notifications/initialized",
	})
	s.mu.Lock()
	stdin := s.stdin
	s.mu.Unlock()
	if stdin == nil {
		return errors.New("notifications/initialized failed: transport closed")
	}
	if err := s.write(ctx, stdin, append(nb, '\n')); err != nil {
		return fmt.Errorf("notifications/initialized failed: %w", err)
	}
	return nil
}

func (s *MCPServer) Call(ctx context.Context, method string, params any) (string, error) {
	if err := s.acquire(ctx); err != nil {
		return "", fmt.Errorf("mcp %s: waiting for transport: %w", s.name, err)
	}
	held := true
	defer func() {
		if held {
			s.release()
		}
	}()

	if err := s.ensureStarted(ctx); err != nil {
		return "", err
	}
	req, err := s.send(ctx, method, params)
	if err != nil {
		return "", err
	}
	defer s.deregister(req.id)

	// Admission covers only start and write; the response wait is cancellable
	// and does not block other callers.
	s.release()
	held = false
	return s.await(ctx, req)
}

// send registers a pending id and writes the request. Admission must be held.
func (s *MCPServer) send(ctx context.Context, method string, params any) (mcpRequest, error) {
	s.mu.Lock()
	if s.stdin == nil || s.dead {
		s.mu.Unlock()
		return mcpRequest{}, fmt.Errorf("mcp %s: transport not running", s.name)
	}
	s.lastID++
	req := mcpRequest{id: s.lastID, ch: make(chan mcpResult, 1), done: s.readerDone}
	s.pending[req.id] = req.ch
	stdin := s.stdin
	s.mu.Unlock()

	msg := map[string]any{
		"jsonrpc": "2.0",
		"id":      req.id,
		"method":  method,
	}
	if params != nil {
		msg["params"] = params
	}
	b, err := json.Marshal(msg)
	if err != nil {
		s.deregister(req.id)
		return mcpRequest{}, fmt.Errorf("mcp %s: marshal request: %w", s.name, err)
	}
	slog.Debug("mcp: sending request", "server", s.name, "req", string(b))
	if err := s.write(ctx, stdin, append(b, '\n')); err != nil {
		s.deregister(req.id)
		return mcpRequest{}, err
	}
	return req, nil
}

// write sends b without ever leaving a goroutine blocked on an uncancellable
// pipe write: if ctx ends first, the transport is torn down, which breaks the
// pipe, and the write goroutine is joined before returning.
func (s *MCPServer) write(ctx context.Context, stdin io.Writer, b []byte) error {
	if err := ctx.Err(); err != nil {
		return fmt.Errorf("mcp %s write request: %w", s.name, err)
	}
	done := make(chan error, 1)
	go func() {
		_, err := stdin.Write(b)
		done <- err
	}()
	select {
	case err := <-done:
		if err != nil {
			s.teardown()
			return fmt.Errorf("mcp %s write request: %w", s.name, err)
		}
		return nil
	case <-ctx.Done():
		s.teardown()
		<-done
		return fmt.Errorf("mcp %s write request canceled: %w", s.name, ctx.Err())
	}
}

func (s *MCPServer) await(ctx context.Context, req mcpRequest) (string, error) {
	select {
	case res := <-req.ch:
		return res.line, res.err
	case <-ctx.Done():
		return "", fmt.Errorf("mcp %s call: %w", s.name, ctx.Err())
	case <-req.done:
		select {
		case res := <-req.ch:
			return res.line, res.err
		default:
		}
		return "", fmt.Errorf("mcp %s: transport closed before response id %d", s.name, req.id)
	}
}

// mcpTool now uses a shared server instance.
type mcpTool struct {
	server *MCPServer
}

func newMCPTool(name string, cfg config.MCPServerConfig, env map[string]string) *mcpTool {
	return &mcpTool{
		server: &MCPServer{
			name: name,
			cfg:  cfg,
			env:  env,
		},
	}
}

func (t *mcpTool) Name() string {
	return strings.ReplaceAll(t.server.name, "-", "_")
}

type mcpArgs struct {
	Method string         `json:"method" schema:"The JSON-RPC method to call (e.g. 'tools/list', 'tools/call')."`
	Params map[string]any `json:"params,omitempty" schema:"The parameters for the JSON-RPC call."`
}

func (t *mcpTool) Declaration() provider.ToolDeclaration {
	return provider.ToolDeclaration{
		Name:        t.Name(),
		Description: fmt.Sprintf("Execute the %s MCP server with a JSON-RPC request.", t.server.name),
		Parameters:  agent.DeriveSchema(mcpArgs{}),
	}
}

func (t *mcpTool) Execute(ctx context.Context, _, _ string, args map[string]any) (string, error) {
	method, _ := args["method"].(string)
	if method == "" {
		return "", fmt.Errorf("mcp %s: method is required", t.server.name)
	}
	return t.server.Call(ctx, method, args["params"])
}

func (s *MCPServer) serverName() string { return s.name }

type mcpCaller interface {
	start(ctx context.Context) error
	Call(ctx context.Context, method string, params any) (string, error)
	serverName() string
}

// mcpStopper is the optional teardown capability asserted at cleanup time.
type mcpStopper interface {
	stop() error
}

type mcpProxyTool struct {
	server   mcpCaller
	toolName string
	decl     provider.ToolDeclaration
}

func (t *mcpProxyTool) Name() string { return t.decl.Name }

func (t *mcpProxyTool) Declaration() provider.ToolDeclaration { return t.decl }

func (t *mcpProxyTool) Execute(ctx context.Context, _, _ string, args map[string]any) (string, error) {
	resp, err := t.server.Call(ctx, "tools/call", map[string]any{
		"name":      t.toolName,
		"arguments": args,
	})
	if err != nil {
		return "", fmt.Errorf("tools/call: %w", err)
	}
	return resp, nil
}

func sanitizeMCPToolName(name string) string {
	var sb strings.Builder
	for _, c := range name {
		if (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_' {
			sb.WriteRune(c)
		} else {
			sb.WriteRune('_')
		}
	}
	return sb.String()
}

func enumerateMCPTools(ctx context.Context, srv mcpCaller) ([]*mcpProxyTool, error) {
	if err := ctx.Err(); err != nil {
		return nil, fmt.Errorf("tools/list canceled before start: %w", err)
	}
	if err := srv.start(ctx); err != nil {
		return nil, fmt.Errorf("failed to start server: %w", err)
	}

	var proxies []*mcpProxyTool
	seen := make(map[string]bool)
	var params any
	for {
		if err := ctx.Err(); err != nil {
			return nil, fmt.Errorf("tools/list canceled before request: %w", err)
		}
		page, nextCursor, err := enumerateMCPToolsPage(ctx, srv, params)
		if err != nil {
			return nil, err
		}
		proxies = append(proxies, page...)
		if nextCursor == "" {
			return proxies, nil
		}
		if seen[nextCursor] {
			return nil, fmt.Errorf("tools/list repeated continuation cursor %q", nextCursor)
		}
		seen[nextCursor] = true
		params = map[string]any{"cursor": nextCursor}
	}
}

func enumerateMCPToolsPage(ctx context.Context, srv mcpCaller, params any) ([]*mcpProxyTool, string, error) {
	respStr, err := srv.Call(ctx, "tools/list", params)
	if err != nil {
		return nil, "", fmt.Errorf("tools/list call failed: %w", err)
	}

	if err := ctx.Err(); err != nil {
		return nil, "", fmt.Errorf("tools/list canceled after response: %w", err)
	}

	var resp struct {
		Result struct {
			NextCursor string `json:"nextCursor"`
			Tools      []struct {
				Name        string         `json:"name"`
				Description string         `json:"description"`
				InputSchema map[string]any `json:"inputSchema"`
			} `json:"tools"`
		} `json:"result"`
		Error *struct {
			Code    int    `json:"code"`
			Message string `json:"message"`
		} `json:"error"`
	}
	if err := json.Unmarshal([]byte(respStr), &resp); err != nil {
		return nil, "", fmt.Errorf("failed to parse tools/list response: %w", err)
	}

	if resp.Error != nil {
		return nil, "", fmt.Errorf("tools/list returned error: code %d, message %s", resp.Error.Code, resp.Error.Message)
	}

	var proxies []*mcpProxyTool
	for _, t := range resp.Result.Tools {
		proxies = append(proxies, &mcpProxyTool{
			server:   srv,
			toolName: t.Name,
			decl: provider.ToolDeclaration{
				Name:        t.Name, // will be sanitized and disambiguated in tools.go
				Description: t.Description,
				Parameters:  t.InputSchema,
			},
		})
	}
	return proxies, resp.Result.NextCursor, nil
}
