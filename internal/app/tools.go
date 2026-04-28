package app

import (
	"context"
	"encoding/json"
	"errors"
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
	cfg *config.Config
}

// NewReadTextFileTool creates a new ReadTextFileTool instance.
func NewReadTextFileTool(cfg *config.Config) *ReadTextFileTool {
	return &ReadTextFileTool{cfg: cfg}
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

// Execute reads the file from the workspace or project root.
func (t *ReadTextFileTool) Execute(ctx context.Context, sessionKey, userID string, args map[string]any) (string, error) {
	path, _ := args["file_path"].(string)
	if path == "" {
		return "", fmt.Errorf("read_text_file: file_path is required")
	}

	// F-073: Determine workspace root for this user
	workspace := t.cfg.WorkspacePath(userID)
	project := t.cfg.ProjectRoot()

	// 1. Try Workspace Root
	data, err := t.readFileFromRoot(path, workspace)
	if err == nil {
		return string(data), nil
	}
	if !errors.Is(err, os.ErrNotExist) && !strings.Contains(err.Error(), "outside root") {
		return "", fmt.Errorf("read_text_file: %w", err)
	}

	// 2. Try Project Root (source code)
	if project != "" {
		data, err := t.readFileFromRoot(path, project)
		if err == nil {
			return string(data), nil
		}
		if !errors.Is(err, os.ErrNotExist) && !strings.Contains(err.Error(), "outside root") {
			return "", fmt.Errorf("read_text_file: %w", err)
		}
	}

	// If we got here, it's either not found or outside both roots.
	// For security, if it was outside the workspace and project, report that.
	if strings.Contains(err.Error(), "outside root") {
		return "", fmt.Errorf("read_text_file: path %q is outside allowed roots (workspace and project)", path)
	}

	return "", fmt.Errorf("read_text_file: open %s: The system cannot find the file specified in workspace or project root", path)
}

func (t *ReadTextFileTool) readFileFromRoot(path, root string) ([]byte, error) {
	if root == "" {
		return nil, fmt.Errorf("empty root (outside root)")
	}

	fullPath := path
	if !filepath.IsAbs(fullPath) {
		fullPath = filepath.Join(root, path)
	}

	cleanPath := filepath.Clean(fullPath)
	cleanRoot := filepath.Clean(root)

	// Normalize drive letters on Windows for comparison
	if strings.EqualFold(filepath.VolumeName(cleanPath), filepath.VolumeName(cleanRoot)) {
		rel, err := filepath.Rel(cleanRoot, cleanPath)
		if err != nil || strings.HasPrefix(rel, "..") {
			return nil, fmt.Errorf("path %q is outside root %q", path, root)
		}
		data, err := os.ReadFile(cleanPath)
		if err != nil {
			return nil, fmt.Errorf("read file: %w", err)
		}
		return data, nil
	}

	return nil, fmt.Errorf("path %q is on a different drive than root %q (outside root)", path, root)
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
	wireSubTools(tools)
	return tools
}

// wireSubTools finds the SpawnTool in the list and gives it a safe read-only subset
// of tools for sub-agents to use (excludes spawn itself and side-effecting tools).
func wireSubTools(tools []Tool) {
	var spawn *SpawnTool
	for _, t := range tools {
		if s, ok := t.(*SpawnTool); ok {
			spawn = s
			break
		}
	}
	if spawn == nil {
		return
	}
	sub := make([]Tool, 0, len(tools))
	for _, t := range tools {
		if t.Name() == spawnToolName {
			continue
		}
		if t.Declaration().SideEffecting {
			continue
		}
		sub = append(sub, t)
	}
	spawn.SetSubTools(sub)
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
		NewReadTextFileTool(cfg),
		newShellExecTool(cfg, cfg.ExecTimeout(), registry),
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
		gmailSecrets := filepath.Join(secretsRoot, "gmail")
		tools = append(tools, newSendEmailTool(gmailSecrets, cfg.StorageRoot(), userEmail, registry, tracer))
		if cfg.Strategic.GmailReadonly {
			tools = append(tools, newSearchGmailTool(gmailSecrets, tracer))
			tools = append(tools, newReadGmailTool(gmailSecrets, tracer))
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
			browser.NewWaitForTool(client),
			browser.NewExtractTool(client),
			browser.NewGetTextTool(client),
			browser.NewGetTextsTool(client),
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
	// Sanitize sessionKey for Windows (replace colons which are common in telegram:IDs)
	safeKey := strings.ReplaceAll(sessionKey, ":", "_")
	return filepath.Join(r.storageDir, safeKey, "tool_registry.json")
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
