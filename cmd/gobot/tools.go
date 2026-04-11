package main

import (
        "context"
        "fmt"
        "log/slog"
        "os"

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

func (t *ReadTextFileTool) Name() string { return readTextFileToolName }
func (t *ReadTextFileTool) Declaration() provider.ToolDeclaration {
        return provider.ToolDeclaration{
                Name:        readTextFileToolName,
                Description: "Read the complete contents of a text file from the workspace.",
                Parameters: map[string]any{
                        "type": "object",
                        "properties": map[string]any{
                                "path": map[string]any{
                                        "type":        "string",
                                        "description": "The absolute or relative path to the file.",
                                },
                        },
                        "required": []string{"path"},
                },
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
        specialistModels := make(map[string]string, len(cfg.Agents.Specialists))
        for agentType, sc := range cfg.Agents.Specialists {
                if sc.Model != "" {
                        specialistModels[agentType] = sc.Model
                }
        }

        // Register tools.
        secretsRoot := cfg.SecretsRoot()
        tools := []Tool{
                newSpawnTool(prov, model, nil, specialistModels, memStore, cfg),
                &ReadTextFileTool{workspace: cfg.WorkspacePath("", "")},
        }
        tools = append(tools, newShellExecTool(cfg.WorkspacePath("", ""), cfg.ExecTimeout()))

        // Initialize MCP tools from config
        for name, srvCfg := range cfg.Tools.MCPServers {
                env := cfg.MCPEnvFor(name)
                tools = append(tools, newMCPTool(name, srvCfg, env))
                slog.Info("run: registered MCP tool", "server", name)
        }

        if memStore != nil {
        	tools = append(tools, newSearchMemoryTool(memStore, vecStore, embedProv, cfg))
        }
        if memStore != nil && vecStore != nil && embedProv != nil {
                tools = append(tools, newSearchDocsTool(memStore, vecStore, embedProv))
        }

        tools = append(tools, []Tool{
		newListCalendarTool(secretsRoot),
		newCreateCalendarEventTool(secretsRoot),
		newListTasksTool(secretsRoot),
		newCreateTaskTool(secretsRoot),
		newCompleteTaskTool(secretsRoot),
		newUpdateTaskTool(secretsRoot),
	}...)

	googleKey := cfg.GoogleAPIKey()
	googleCX := cfg.GoogleCX()
	if googleKey != "" && googleCX != "" {
		tools = append(tools, newWebSearchTool(googleKey, googleCX))
		slog.Info("run: registered google_search tool")
	} else {
		slog.Warn("run: google_search tool disabled -- providers.google.apiKey or customCx not set")
	}

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
