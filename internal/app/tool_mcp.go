package app

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"os"
	"os/exec"
	"strings"
	"sync"

	"github.com/allthingscode/gobot/internal/agent"
	"github.com/allthingscode/gobot/internal/config"
	"github.com/allthingscode/gobot/internal/provider"
)

// MCPServer manages a persistent MCP subprocess.
type MCPServer struct {
	name string
	cfg  config.MCPServerConfig
	env  map[string]string

	mu     sync.Mutex
	cmd    *exec.Cmd
	stdin  io.WriteCloser
	stdout io.ReadCloser
	stderr bytes.Buffer

	initialized bool
	lastID      int
}

func (s *MCPServer) start(ctx context.Context) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	if s.cmd != nil && s.cmd.Process != nil && s.cmd.ProcessState == nil {
		return nil // already running
	}

	// #nosec G204
	cmd := exec.CommandContext(ctx, s.cfg.Command, s.cfg.Args...)
	cmd.Env = os.Environ()
	for k, v := range s.env {
		cmd.Env = append(cmd.Env, fmt.Sprintf("%s=%s", k, v))
	}

	stdin, err := cmd.StdinPipe()
	if err != nil {
		return fmt.Errorf("stdin pipe: %w", err)
	}
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return fmt.Errorf("stdout pipe: %w", err)
	}
	s.stderr.Reset()
	cmd.Stderr = &s.stderr

	if err := cmd.Start(); err != nil {
		return fmt.Errorf("mcp start %s: %w", s.name, err)
	}

	s.cmd = cmd
	s.stdin = stdin
	s.stdout = stdout
	s.initialized = false
	s.lastID = 0

	// Handshake
	if err := s.handshake(ctx); err != nil {
		_ = s.stop()
		return err
	}

	s.initialized = true
	return nil
}

func (s *MCPServer) stop() error {
	if s.cmd != nil && s.cmd.Process != nil {
		_ = s.cmd.Process.Kill()
		_ = s.cmd.Wait()
	}
	s.cmd = nil
	s.stdin = nil
	s.stdout = nil
	s.initialized = false
	return nil
}

func (s *MCPServer) handshake(ctx context.Context) error {
	// 1. initialize
	s.lastID++
	id := s.lastID
	initReq := map[string]any{
		"jsonrpc": "2.0",
		"id":      id,
		"method":  "initialize",
		"params": map[string]any{
			"protocolVersion": "2024-11-05",
			"capabilities":    map[string]any{},
			"clientInfo": map[string]any{
				"name":    "gobot",
				"version": "1.0.0",
			},
		},
	}
	if _, err := s.callLocked(ctx, id, initReq); err != nil {
		return fmt.Errorf("initialize failed: %w, stderr: %s", err, s.stderr.String())
	}

	// 2. initialized notification
	notif := map[string]any{
		"jsonrpc": "2.0",
		"method":  "notifications/initialized",
	}
	nb, _ := json.Marshal(notif)
	if _, err := s.stdin.Write(append(nb, '\n')); err != nil {
		return fmt.Errorf("notifications/initialized failed: %w", err)
	}

	return nil
}

func (s *MCPServer) Call(ctx context.Context, method string, params any) (string, error) {
	if err := s.start(ctx); err != nil {
		return "", err
	}

	s.mu.Lock()
	defer s.mu.Unlock()

	s.lastID++
	id := s.lastID
	req := map[string]any{
		"jsonrpc": "2.0",
		"id":      id,
		"method":  method,
	}
	if params != nil {
		req["params"] = params
	}

	return s.callLocked(ctx, id, req)
}

func (s *MCPServer) callLocked(ctx context.Context, id int, req any) (string, error) {
	b, _ := json.Marshal(req)
	slog.Debug("mcp: sending request", "server", s.name, "req", string(b))
	if _, err := s.stdin.Write(append(b, '\n')); err != nil {
		return "", fmt.Errorf("mcp write request: %w", err)
	}

	// Read from stdout until we get a response with the matching ID.
	// We use a separate goroutine and a channel to support context cancellation.
	type scanResult struct {
		line string
		err  error
	}
	resChan := make(chan scanResult, 1)

	go func() {
		scanner := bufio.NewScanner(s.stdout)
		const maxTokenSize = 10 * 1024 * 1024 // 10MB buffer for large git/filesystem outputs
		buf := make([]byte, 0, 64*1024)
		scanner.Buffer(buf, maxTokenSize)

		for scanner.Scan() {
			line := scanner.Text()
			if line == "" {
				continue
			}

			var resp struct {
				ID int `json:"id"`
			}
			// Attempt to peek at the ID. Skip if not a valid JSON object or missing ID.
			if err := json.Unmarshal([]byte(line), &resp); err == nil && resp.ID == id {
				resChan <- scanResult{line: line}
				return
			}
			// If it's a notification or different ID, keep scanning.
			slog.Debug("mcp: ignoring line", "server", s.name, "id", resp.ID, "expected", id)
		}
		if err := scanner.Err(); err != nil {
			resChan <- scanResult{err: fmt.Errorf("mcp scan error: %w", err)}
		} else {
			resChan <- scanResult{err: fmt.Errorf("mcp: EOF before response id %d", id)}
		}
	}()

	select {
	case <-ctx.Done():
		return "", fmt.Errorf("mcp call: %w", ctx.Err())
	case res := <-resChan:
		return res.line, res.err
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
	if err := srv.start(ctx); err != nil {
		return nil, fmt.Errorf("failed to start server: %w", err)
	}

	respStr, err := srv.Call(ctx, "tools/list", nil)
	if err != nil {
		return nil, fmt.Errorf("tools/list call failed: %w", err)
	}

	var resp struct {
		Result struct {
			Tools []struct {
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
		return nil, fmt.Errorf("failed to parse tools/list response: %w", err)
	}

	if resp.Error != nil {
		return nil, fmt.Errorf("tools/list returned error: code %d, message %s", resp.Error.Code, resp.Error.Message)
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
	return proxies, nil
}
