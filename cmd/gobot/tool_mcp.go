package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"os"
	"os/exec"
	"strings"

	"google.golang.org/genai"

	"github.com/allthingscode/gobot/internal/config"
)

type mcpTool struct {
	serverName string
	cfg        config.MCPServerConfig
	env        map[string]string
}

func newMCPTool(serverName string, cfg config.MCPServerConfig, env map[string]string) *mcpTool {
	return &mcpTool{
		serverName: serverName,
		cfg:        cfg,
		env:        env,
	}
}

func (t *mcpTool) Name() string {
	return strings.ReplaceAll(t.serverName, "-", "_")
}

func (t *mcpTool) Declaration() *genai.FunctionDeclaration {
	return &genai.FunctionDeclaration{
		Name:        t.Name(),
		Description: fmt.Sprintf("Execute the %s MCP server with a JSON-RPC request.", t.serverName),
		Parameters: &genai.Schema{
			Type: genai.TypeObject,
			Properties: map[string]*genai.Schema{
				"method": {
					Type:        genai.TypeString,
					Description: "The JSON-RPC method to call (e.g. 'tools/list', 'tools/call').",
				},
				"params": {
					Type:        genai.TypeObject,
					Description: "The parameters for the JSON-RPC call.",
				},
			},
			Required: []string{"method"},
		},
	}
}

func (t *mcpTool) Execute(ctx context.Context, sessionKey string, args map[string]any) (string, error) {
	method, _ := args["method"].(string)
	if method == "" {
		return "", fmt.Errorf("mcp %s: method is required", t.serverName)
	}

	req := map[string]any{
		"jsonrpc": "2.0",
		"id":      1,
		"method":  method,
	}
	if p, ok := args["params"]; ok {
		req["params"] = p
	}

	reqBytes, err := json.Marshal(req)
	if err != nil {
		return "", fmt.Errorf("mcp marshal: %w", err)
	}

	cmd := exec.CommandContext(ctx, t.cfg.Command, t.cfg.Args...)
	cmd.Env = os.Environ()
	for k, v := range t.env {
		cmd.Env = append(cmd.Env, fmt.Sprintf("%s=%s", k, v))
	}

	cmd.Stdin = bytes.NewReader(reqBytes)
	var stdout, stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr

	slog.Info("mcp: executing server", "server", t.serverName, "method", method)
	if err := cmd.Run(); err != nil {
		return "", fmt.Errorf("mcp execute %s failed: %w, stderr: %s", t.serverName, err, stderr.String())
	}

	return stdout.String(), nil
}
