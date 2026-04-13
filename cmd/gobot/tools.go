package main

import (
	"context"
	"fmt"
	"log/slog"
	"os"

	"github.com/allthingscode/gobot/internal/agent"
	"github.com/allthingscode/gobot/internal/config"
	"github.com/allthingscode/gobot/internal/memory"
	"github.com/allthingscode/gobot/internal/memory/vector"
	"github.com/allthingscode/gobot/internal/provider"
)

const (
	sendEmailToolName    = "send_email"
	readTextFileToolName = "read_text_file"
)

// ReadTextFileTool implements Tool and reads a file from the workspace.
type ReadTextFileTool struct {
	workspace string
}

type readTextFileArgs struct {
	Path string `json:"path" schema:"The absolute or relative path to the file."`
}

func (t *ReadTextFileTool) Name() string { return readTextFileToolName }
func (t *ReadTextFileTool) Declaration() provider.ToolDeclaration {
	return provider.ToolDeclaration{
		Name:        readTextFileToolName,
		Description: "Read the complete contents of a text file from the workspace.",
		Parameters:  agent.DeriveSchema(readTextFileArgs{}),
	}
}

func (t *ReadTextFileTool) Execute(ctx context.Context, sessionKey, userID string, args map[string]any) (string, error) {
	path, _ := args["path"].(string)
	if path == "" {
		return "", fmt.Errorf("read_text_file: path is required")
	}
	data, err := os.ReadFile(path)
	if err != nil {
		return "", fmt.Errorf("read_text_file: %w", err)
	}
	return string(data), nil
}

// registerTools initializes all tools (spawn, shell, MCP, google, etc) and returns them.
func registerTools(cfg *config.Config, prov provider.Provider, model string, memStore *memory.MemoryStore, vecStore *vector.Store, embedProv vector.EmbeddingProvider) []Tool {
	specialistModels := buildSpecialistModels(cfg)
	secretsRoot := cfg.SecretsRoot()
	tools := buildBaseTools(cfg, prov, model, specialistModels, memStore, vecStore, embedProv)
	tools = appendMCPtools(cfg, tools)
	tools = appendMemoryTools(memStore, vecStore, embedProv, cfg, tools)
	tools = appendCalendarTaskTools(secretsRoot, tools)
	tools = appendGoogleTools(cfg, tools)
	tools = appendGmailTools(cfg, secretsRoot, tools)
	return tools
}

func buildSpecialistModels(cfg *config.Config) map[string]string {
	specialistModels := make(map[string]string, len(cfg.Agents.Specialists))
	for agentType, sc := range cfg.Agents.Specialists {
		if sc.Model != "" {
			specialistModels[agentType] = sc.Model
		}
	}
	return specialistModels
}

func buildBaseTools(cfg *config.Config, prov provider.Provider, model string, specialistModels map[string]string, memStore *memory.MemoryStore, vecStore *vector.Store, embedProv vector.EmbeddingProvider) []Tool {
	return []Tool{
		newSpawnTool(prov, model, nil, specialistModels, memStore, cfg),
		&ReadTextFileTool{workspace: cfg.WorkspacePath("", "")},
		newShellExecTool(cfg.WorkspacePath("", ""), cfg.ExecTimeout()),
	}
}

func appendMCPtools(cfg *config.Config, tools []Tool) []Tool {
	for name, srvCfg := range cfg.Tools.MCPServers {
		env := cfg.MCPEnvFor(name)
		tools = append(tools, newMCPTool(name, srvCfg, env))
		slog.Info("run: registered MCP tool", "server", name)
	}
	return tools
}

func appendMemoryTools(memStore *memory.MemoryStore, vecStore *vector.Store, embedProv vector.EmbeddingProvider, cfg *config.Config, tools []Tool) []Tool {
	if memStore != nil {
		tools = append(tools, newSearchMemoryTool(memStore, vecStore, embedProv, cfg))
	}
	if memStore != nil && vecStore != nil && embedProv != nil {
		tools = append(tools, newSearchDocsTool(memStore, vecStore, embedProv))
	}
	return tools
}

func appendCalendarTaskTools(secretsRoot string, tools []Tool) []Tool {
	return append(tools, []Tool{
		newListCalendarTool(secretsRoot),
		newCreateCalendarEventTool(secretsRoot),
		newListTasksTool(secretsRoot),
		newCreateTaskTool(secretsRoot),
		newCompleteTaskTool(secretsRoot),
		newUpdateTaskTool(secretsRoot),
	}...)
}

func appendGoogleTools(cfg *config.Config, tools []Tool) []Tool {
	googleKey := cfg.GoogleAPIKey()
	googleCX := cfg.GoogleCX()
	if googleKey != "" && googleCX != "" {
		tools = append(tools, newWebSearchTool(googleKey, googleCX))
		slog.Info("run: registered google_search tool")
	} else {
		slog.Warn("run: google_search tool disabled -- providers.google.apiKey or customCx not set")
	}
	return tools
}

func appendGmailTools(cfg *config.Config, secretsRoot string, tools []Tool) []Tool {
	if userEmail := cfg.Strategic.UserEmail; userEmail != "" {
		tools = append(tools, newSendEmailTool(secretsRoot, cfg.StorageRoot(), userEmail))
		tools = append(tools, newSearchGmailTool(secretsRoot))
		tools = append(tools, newReadGmailTool(secretsRoot))
		slog.Info("run: registered gmail tools (send, search, read)")
	} else {
		slog.Warn("run: send_email tool disabled -- strategic_edition.user_email not set in config")
	}
	return tools
}

// Tool is a function the agent can invoke during a conversation turn.
type Tool interface {
	// Name returns the function name.
	Name() string

	// Declaration returns the provider-agnostic tool declaration.
	Declaration() provider.ToolDeclaration

	// Execute runs the tool with the supplied arguments.
	// userID is used for workspace and memory isolation (F-073).
	Execute(ctx context.Context, sessionKey, userID string, args map[string]any) (string, error)
}
