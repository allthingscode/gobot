package app

import (
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"os"
	"path/filepath"
	"strings"
	"sync"

	"github.com/allthingscode/gobot/internal/agent"
	"github.com/allthingscode/gobot/internal/browser"
	"github.com/allthingscode/gobot/internal/config"
	"github.com/allthingscode/gobot/internal/memory"
	"github.com/allthingscode/gobot/internal/memory/vector"
	"github.com/allthingscode/gobot/internal/observability"
	"github.com/allthingscode/gobot/internal/provider"
)

const (
	readTextFileToolName = "read_text_file"
)

// ReadTextFileTool implements Tool and reads a file from the workspace.
type ReadTextFileTool struct {
	workspace string
}

// NewReadTextFileTool creates a new ReadTextFileTool instance.
func NewReadTextFileTool(workspace string) *ReadTextFileTool {
	return &ReadTextFileTool{workspace: workspace}
}

type readTextFileArgs struct {
	Path string `json:"file_path" schema:"The absolute or relative path to the file within the workspace."`
}

// Name returns the tool name.
func (t *ReadTextFileTool) Name() string { return readTextFileToolName }

// Declaration returns the tool declaration for the provider.
func (t *ReadTextFileTool) Declaration() provider.ToolDeclaration {
	return provider.ToolDeclaration{
		Name:        readTextFileToolName,
		Description: "Read the complete contents of a text file from the agent workspace.",
		Parameters:  agent.DeriveSchema(readTextFileArgs{}),
	}
}

// Execute reads the file from the workspace.
func (t *ReadTextFileTool) Execute(ctx context.Context, sessionKey, userID string, args map[string]any) (string, error) {
	path, _ := args["file_path"].(string)
	if path == "" {
		return "", fmt.Errorf("read_text_file: file_path is required")
	}

	// Resolve to absolute path relative to workspace if not already absolute.
	if !filepath.IsAbs(path) {
		path = filepath.Join(t.workspace, path)
	}

	// Enforce sandbox: path must be within the workspace directory.
	cleanPath := filepath.Clean(path)
	cleanWorkspace := filepath.Clean(t.workspace)
	rel, err := filepath.Rel(cleanWorkspace, cleanPath)
	if err != nil || strings.HasPrefix(rel, "..") || filepath.IsAbs(rel) {
		return "", fmt.Errorf("read_text_file: path %q is outside workspace", path)
	}

	data, err := os.ReadFile(cleanPath)
	if err != nil {
		return "", fmt.Errorf("read_text_file: %w", err)
	}
	return string(data), nil
}

// RegisterTools initializes all tools (spawn, shell, MCP, google, etc) and returns them.
func RegisterTools(cfg *config.Config, prov provider.Provider, model string, memStore *memory.MemoryStore, vecStore *vector.Store, embedProv vector.EmbeddingProvider, registry *ToolRegistry, tracer *observability.DispatchTracer) []Tool {
	specialistModels := buildSpecialistModels(cfg)
	secretsRoot := cfg.SecretsRoot()
	tools := buildBaseTools(cfg, prov, model, specialistModels, memStore, vecStore, embedProv, registry)
	tools = appendCalendarTaskTools(secretsRoot, tools, tracer)
	tools = appendMCPtools(cfg, tools)
	tools = appendMemoryTools(memStore, vecStore, embedProv, cfg, tools, tracer)
	tools = appendGoogleTools(cfg, tools, tracer)
	tools = appendGmailTools(cfg, secretsRoot, tools, registry, tracer)
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

func buildBaseTools(cfg *config.Config, prov provider.Provider, model string, specialistModels map[string]string, memStore *memory.MemoryStore, vecStore *vector.Store, embedProv vector.EmbeddingProvider, registry *ToolRegistry) []Tool {
	tools := []Tool{
		newSpawnTool(prov, model, nil, specialistModels, memStore, cfg),
		&ReadTextFileTool{workspace: cfg.WorkspacePath("", "")},
		newShellExecTool(cfg.WorkspacePath("", ""), cfg.ExecTimeout(), registry),
	}
	return appendBrowserTools(cfg, tools)
}

//nolint:gochecknoglobals // mockable function for testing
var enumerateMCPToolsFunc = enumerateMCPTools

func appendMCPtools(cfg *config.Config, tools []Tool) []Tool {
	existingNames := make(map[string]bool)
	for _, t := range tools {
		existingNames[t.Name()] = true
	}

	for name, srvCfg := range cfg.Tools.MCPServers {
		env := cfg.MCPEnvFor(name)
		srv := &MCPServer{name: name, cfg: srvCfg, env: env}

		proxies, err := enumerateMCPToolsFunc(context.Background(), srv)
		if err != nil {
			slog.Warn("mcp: failed to enumerate tools, registering passthrough", "server", name, "err", err)
			tools = append(tools, newMCPTool(name, srvCfg, env))
			continue
		}
		for _, p := range proxies {
			finalName := sanitizeMCPToolName(p.toolName)
			if existingNames[finalName] {
				finalName = sanitizeMCPToolName(srv.serverName()) + "__" + finalName
			}
			existingNames[finalName] = true
			p.decl.Name = finalName

			tools = append(tools, p)
			slog.Info("run: registered MCP proxy tool", "server", name, "tool", p.toolName)
		}
	}
	return tools
}

func appendMemoryTools(memStore *memory.MemoryStore, vecStore *vector.Store, embedProv vector.EmbeddingProvider, cfg *config.Config, tools []Tool, tracer *observability.DispatchTracer) []Tool {
	if memStore != nil {
		tools = append(tools, NewSearchMemoryTool(memStore, tracer))
	}
	if memStore != nil && vecStore != nil && embedProv != nil {
		tools = append(tools, newSearchDocsTool(memStore, vecStore, embedProv, tracer))
	}
	return tools
}

func appendCalendarTaskTools(secretsRoot string, tools []Tool, tracer *observability.DispatchTracer) []Tool {
	return append(tools, []Tool{
		newListCalendarTool(secretsRoot, tracer),
		newCreateCalendarEventTool(secretsRoot, tracer),
		newListTasksTool(secretsRoot, tracer),
		newCreateTaskTool(secretsRoot, tracer),
		newCompleteTaskTool(secretsRoot, tracer),
		newUpdateTaskTool(secretsRoot, tracer),
	}...)
}

func appendGoogleTools(cfg *config.Config, tools []Tool, tracer *observability.DispatchTracer) []Tool {
	googleKey := cfg.GoogleAPIKey()
	googleCX := cfg.GoogleCX()
	if googleKey != "" && googleCX != "" {
		tools = append(tools, newWebSearchTool(googleKey, googleCX, tracer))
		slog.Info("run: registered google_search tool")
	} else {
		slog.Warn("run: google_search tool disabled -- providers.google.apiKey or customCx not set")
	}
	return tools
}

func appendGmailTools(cfg *config.Config, secretsRoot string, tools []Tool, registry *ToolRegistry, tracer *observability.DispatchTracer) []Tool {
	if userEmail := cfg.Strategic.UserEmail; userEmail != "" {
		tools = append(tools, newSendEmailTool(secretsRoot, cfg.StorageRoot(), userEmail, registry, tracer))
		if cfg.Strategic.GmailReadonly {
			tools = append(tools, newSearchGmailTool(secretsRoot, tracer))
			tools = append(tools, newReadGmailTool(secretsRoot, tracer))
			slog.Info("run: registered gmail tools (send, search, read)")
		} else {
			slog.Info("run: registered gmail tools (send only; gmail_readonly=false)")
		}
	} else {
		slog.Warn("run: send_email tool disabled -- strategic_edition.user_email not set in config")
	}
	return tools
}

func appendBrowserTools(cfg *config.Config, tools []Tool) []Tool {
	if cfg.Browser.DebugPort > 0 || cfg.Browser.Headless {
		client, err := browser.NewClient(cfg.Browser)
		if err != nil {
			slog.Warn("browser: failed to initialize client, skipping tools", "err", err)
			return tools
		}
		tools = append(tools,
			browser.NewNavigateTool(client),
			browser.NewScreenshotTool(client),
			browser.NewGetTextTool(client),
			browser.NewClickTool(client),
			browser.NewTypeTool(client),
		)
		slog.Info("run: registered browser tools")
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

// ToolRegistry manages a task-scoped JSON registry for tool idempotency.
type ToolRegistry struct {
	mu         sync.Mutex
	storageDir string
}

// NewToolRegistry creates a new ToolRegistry rooted in storageDir.
func NewToolRegistry(storageDir string) *ToolRegistry {
	return &ToolRegistry{storageDir: storageDir}
}

type toolRegistryData struct {
	Executions map[string]string `json:"executions"`
}

func (r *ToolRegistry) getPath(sessionKey string) string {
	return filepath.Join(r.storageDir, sessionKey, "tool_registry.json")
}

// Check verifies if an executionID has already been recorded for the session.
func (r *ToolRegistry) Check(sessionKey, executionID string) (string, bool) {
	r.mu.Lock()
	defer r.mu.Unlock()

	data, err := r.load(sessionKey)
	if err != nil {
		return "", false
	}
	res, ok := data.Executions[executionID]
	return res, ok
}

// Store records a successful tool execution result for an executionID.
func (r *ToolRegistry) Store(sessionKey, executionID, result string) error {
	r.mu.Lock()
	defer r.mu.Unlock()

	data, err := r.load(sessionKey)
	if err != nil {
		data = &toolRegistryData{Executions: make(map[string]string)}
	}
	data.Executions[executionID] = result
	return r.save(sessionKey, data)
}

func (r *ToolRegistry) load(sessionKey string) (*toolRegistryData, error) {
	path := r.getPath(sessionKey)
	b, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("read registry: %w", err)
	}
	var data toolRegistryData
	if err := json.Unmarshal(b, &data); err != nil {
		return nil, fmt.Errorf("unmarshal registry: %w", err)
	}
	return &data, nil
}

func (r *ToolRegistry) save(sessionKey string, data *toolRegistryData) error {
	path := r.getPath(sessionKey)
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return fmt.Errorf("mkdir registry: %w", err)
	}
	b, err := json.MarshalIndent(data, "", "  ")
	if err != nil {
		return fmt.Errorf("marshal registry: %w", err)
	}
	if err := os.WriteFile(path, b, 0o600); err != nil {
		return fmt.Errorf("write registry: %w", err)
	}
	return nil
}
