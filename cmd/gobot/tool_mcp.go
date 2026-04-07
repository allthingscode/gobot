package main

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
	cmd := exec.Command(s.cfg.Command, s.cfg.Args...)
	cmd.Env = os.Environ()
	for k, v := range s.env {
		cmd.Env = append(cmd.Env, fmt.Sprintf("%s=%s", k, v))
	}

	stdin, err := cmd.StdinPipe()
	if err != nil {
		return err
	}
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return err
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
	if err := s.handshake(); err != nil {
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

func (s *MCPServer) handshake() error {
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
	if _, err := s.callLocked(id, initReq); err != nil {
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

	return s.callLocked(id, req)
}

func (s *MCPServer) callLocked(id int, req any) (string, error) {
	b, _ := json.Marshal(req)
	slog.Debug("mcp: sending request", "server", s.name, "req", string(b))
	if _, err := s.stdin.Write(append(b, '\n')); err != nil {
		return "", err
	}

	// Read from stdout until we get a response with the matching ID
	scanner := bufio.NewScanner(s.stdout)
	const maxTokenSize = 10 * 1024 * 1024 // 10MB buffer for large git/filesystem outputs
	buf := make([]byte, 0, 64*1024)
	scanner.Buffer(buf, maxTokenSize)

	for scanner.Scan() {
		line := scanner.Bytes()
		if len(line) == 0 {
			continue
		}
		slog.Debug("mcp: received line", "server", s.name, "len", len(line))

		var resp struct {
			ID int `json:"id"`
		}
		// Attempt to peek at the ID. Skip if not a valid JSON object or missing ID.
		if err := json.Unmarshal(line, &resp); err == nil && resp.ID == id {
			return string(line), nil
		}
		// If it's a notification or different ID, keep scanning.
	}
	if err := scanner.Err(); err != nil {
		return "", err
	}
	return "", fmt.Errorf("mcp: EOF before response id %d", id)
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

func (t *mcpTool) Declaration() provider.ToolDeclaration {
	return provider.ToolDeclaration{
		Name:        t.Name(),
		Description: fmt.Sprintf("Execute the %s MCP server with a JSON-RPC request.", t.server.name),
		Parameters: map[string]any{
			"type": "object",
			"properties": map[string]any{
				"method": map[string]any{
					"type":        "string",
					"description": "The JSON-RPC method to call (e.g. 'tools/list', 'tools/call').",
				},
				"params": map[string]any{
					"type":        "object",
					"description": "The parameters for the JSON-RPC call.",
				},
			},
			"required": []string{"method"},
		},
	}
}

func (t *mcpTool) Execute(ctx context.Context, _ string, args map[string]any) (string, error) {
	method, _ := args["method"].(string)
	if method == "" {
		return "", fmt.Errorf("mcp %s: method is required", t.server.name)
	}
	return t.server.Call(ctx, method, args["params"])
}
