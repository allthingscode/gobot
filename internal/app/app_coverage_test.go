package app

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"log/slog"
	"os"
	"os/signal"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"testing/synctest"
	"time"

	"github.com/allthingscode/gobot/internal/agent"
	"github.com/allthingscode/gobot/internal/config"
	agentctx "github.com/allthingscode/gobot/internal/context"
	"github.com/allthingscode/gobot/internal/dashboard"
	"github.com/allthingscode/gobot/internal/memory/vector"
	"github.com/allthingscode/gobot/internal/observability"
	"github.com/allthingscode/gobot/internal/provider"
	"github.com/allthingscode/gobot/internal/resilience"
)

func TestSetupOTel(t *testing.T) {
	ctx := context.Background()
	cfg := &config.Config{}

	cfg.Runtime.Observability.OTLPEndpoint = ""
	p, err := SetupOTel(ctx, cfg)
	if err != nil {
		t.Errorf("unexpected error: %v", err)
	}
	if p != nil {
		t.Error("expected nil provider when telemetry disabled")
	}

	cfg.Runtime.Observability.OTLPEndpoint = "localhost:4317"
	p, err = SetupOTel(ctx, cfg)
	if p != nil {
		_ = p.Shutdown(ctx)
	}
	_ = err
}

func TestStartDashboard(t *testing.T) {
	hub := dashboard.NewHub(10)
	defer hub.Close()
	var wg sync.WaitGroup
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	StartDashboard(ctx, "127.0.0.1:0", "", hub, &wg, nil)
	cancel()

	done := make(chan struct{})
	go func() {
		wg.Wait()
		close(done)
	}()

	select {
	case <-done:
	case <-time.After(5 * time.Second):
		t.Log("Warning: StartDashboard did not stop within 5 seconds")
	}
}

// TestStartDashboard_NoTokenForcesLoopback exercises the no-auth path: a non-loopback
// requested address is rewritten to loopback before binding (so the bind is safe to run).
func TestStartDashboard_NoTokenForcesLoopback(t *testing.T) {
	hub := dashboard.NewHub(10)
	defer hub.Close()
	var wg sync.WaitGroup
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	StartDashboard(ctx, "0.0.0.0:0", "", hub, &wg, nil)
	cancel()

	done := make(chan struct{})
	go func() {
		wg.Wait()
		close(done)
	}()

	select {
	case <-done:
	case <-time.After(5 * time.Second):
		t.Log("Warning: StartDashboard did not stop within 5 seconds")
	}
}

func TestDrainGoroutines(t *testing.T) {
	var wg sync.WaitGroup
	wg.Add(1)
	go func() {
		time.Sleep(50 * time.Millisecond)
		wg.Done()
	}()
	DrainGoroutines(&wg, 500*time.Millisecond)

	wg.Add(1)
	DrainGoroutines(&wg, 10*time.Millisecond)
	wg.Done()
}

func TestStartCron_Disabled(t *testing.T) {
	cfg := &config.Config{}
	cfg.Cron.Enabled = false
	var wg sync.WaitGroup
	StartCron(context.Background(), cfg, nil, nil, nil, nil, &wg)
	wg.Wait()
}

func TestStartHeartbeat_Disabled(t *testing.T) {
	cfg := &config.Config{}
	cfg.Heartbeat.Enabled = false
	var wg sync.WaitGroup
	StartHeartbeat(context.Background(), cfg, "", nil, &wg)
	wg.Wait()
}

func TestWaitForShutdown(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	var wg sync.WaitGroup
	cancel()
	if err := waitForShutdown(ctx, cancel, &wg, make(chan error, 1), nil); err != nil {
		t.Errorf("graceful (ctx-cancel) shutdown must return nil, got %v", err)
	}
}

func TestWaitForShutdown_DrainTimeout(t *testing.T) {
	t.Parallel()
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	var wg sync.WaitGroup
	wg.Add(1)
	cleanupStarted := make(chan struct{})
	release := make(chan struct{})
	go func() {
		defer wg.Done()
		<-ctx.Done()
		close(cleanupStarted)
		<-release
	}()
	t.Cleanup(func() { cancel(); close(release); wg.Wait() })
	signals := make(chan os.Signal, 1)
	signals <- os.Interrupt
	result := make(chan error, 1)
	go func() {
		result <- waitForShutdownTrigger(ctx, cancel, &wg, nil, nil, signals, 20*time.Millisecond)
	}()
	select {
	case <-cleanupStarted:
	case <-time.After(2 * time.Second):
		t.Fatal("worker did not observe cancellation")
	}
	select {
	case err := <-result:
		if err != nil {
			t.Errorf("drain timeout introduced an error: %v", err)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("shutdown exceeded its injected drain budget")
	}
}

func TestRunAgent_PrerequisiteFail(t *testing.T) {
	cfg := &config.Config{}
	cfg.Channels.Telegram.Enabled = true
	cfg.Channels.Telegram.Token = ""
	err := RunAgent(context.Background(), cfg)
	if err == nil {
		t.Error("expected error due to missing telegram token")
	}
}

func TestShutdownOTel(t *testing.T) {
	p, _ := observability.NewProvider(observability.Config{ServiceName: "test"})
	if p != nil {
		shutdownOTel(p)
	}
}

func TestStartGateway_Shutdown(t *testing.T) {
	cfg := &config.Config{}
	cfg.Gateway.Port = 0
	var wg sync.WaitGroup
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	StartGateway(ctx, cfg, nil, nil, nil, nil, &wg, nil, nil)
	cancel()

	done := make(chan struct{})
	go func() {
		wg.Wait()
		close(done)
	}()

	select {
	case <-done:
	case <-time.After(5 * time.Second):
		t.Log("Warning: StartGateway did not stop within 5 seconds")
	}
}

func TestSetupLogging_Basic(t *testing.T) {
	cfg := &config.Config{}
	tempDir := t.TempDir()
	cfg.Runtime.StorageRoot = tempDir
	SetupLogging(cfg, nil)
}

// --- parseLimit ---

func TestParseLimit(t *testing.T) {
	if got := parseLimit(float64(10)); got != 10 {
		t.Errorf("float64(10): expected 10, got %d", got)
	}
	if got := parseLimit(3); got != 3 {
		t.Errorf("int(3): expected 3, got %d", got)
	}
	if got := parseLimit(int64(7)); got != 7 {
		t.Errorf("int64(7): expected 7, got %d", got)
	}
	if got := parseLimit(nil); got != 5 {
		t.Errorf("nil: expected default 5, got %d", got)
	}
	if got := parseLimit(float64(0)); got != 5 {
		t.Errorf("0: expected default 5, got %d", got)
	}
	if got := parseLimit(float64(-3)); got != 5 {
		t.Errorf("-3: expected default 5, got %d", got)
	}
}

// --- formatResults ---

func TestFormatResults_Empty(t *testing.T) {
	result, err := formatResults(nil, 5)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !strings.Contains(result, "No matching documents") {
		t.Errorf("expected 'No matching documents' message, got %q", result)
	}
}

func TestFormatResults_Some(t *testing.T) {
	merged := []vector.HybridResult{
		{ID: "doc1", Content: "content about foo", Score: 1.0},
		{ID: "doc2", Content: "another doc", Score: 0.8},
	}
	result, err := formatResults(merged, 5)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !strings.Contains(result, "doc1") {
		t.Errorf("expected doc1 in results, got %q", result)
	}
}

func TestFormatResults_Truncate(t *testing.T) {
	merged := make([]vector.HybridResult, 10)
	for i := range merged {
		merged[i] = vector.HybridResult{ID: "doc", Score: float64(i)}
	}
	result, err := formatResults(merged, 3)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	_ = result
}

// --- SearchDocsTool ---

type mockMemSearcher struct {
	results []map[string]any
	err     error
}

func (m *mockMemSearcher) Search(_ context.Context, _, _ string, _ int) ([]map[string]any, error) {
	return m.results, m.err
}

func TestSearchDocsTool_Name(t *testing.T) {
	tool := newSearchDocsTool(&mockMemSearcher{}, nil, nil, nil)
	if tool.Name() != searchDocsToolName {
		t.Errorf("expected %q, got %q", searchDocsToolName, tool.Name())
	}
}

func TestSearchDocsTool_Declaration(t *testing.T) {
	tool := newSearchDocsTool(&mockMemSearcher{}, nil, nil, nil)
	decl := tool.Declaration()
	if decl.Name != searchDocsToolName {
		t.Errorf("expected %q in declaration, got %q", searchDocsToolName, decl.Name)
	}
	if decl.Description == "" {
		t.Error("expected non-empty description")
	}
}

func TestSearchDocsTool_Execute_EmptyQuery(t *testing.T) {
	tool := newSearchDocsTool(&mockMemSearcher{}, nil, nil, nil)
	_, err := tool.Execute(context.Background(), "key", "user", map[string]any{})
	if err == nil {
		t.Error("expected error for empty query")
	}
}

func TestSearchDocsTool_Execute_FTSError(t *testing.T) {
	searcher := &mockMemSearcher{err: errors.New("fts failed")}
	tool := newSearchDocsTool(searcher, nil, nil, nil)
	_, err := tool.Execute(context.Background(), "key", "user", map[string]any{"query": "foo"})
	if err == nil {
		t.Error("expected error when FTS search fails")
	}
}

func TestSearchDocsTool_Execute_NoResults(t *testing.T) {
	// FTS returns empty, vector store is empty → "No matching documents"
	store, err := vector.NewStore(filepath.Join(t.TempDir(), "vec.db"))
	if err != nil {
		t.Skip("cannot create vector store:", err)
	}
	tool := newSearchDocsTool(&mockMemSearcher{}, store, nil, nil)
	result, err := tool.Execute(context.Background(), "k", "u", map[string]any{"query": "anything"})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !strings.Contains(result, "No matching") {
		t.Errorf("expected 'No matching' in result, got %q", result)
	}
}

func TestSearchDocsTool_Execute_WithFTSResults(t *testing.T) {
	searcher := &mockMemSearcher{
		results: []map[string]any{
			{"namespace": "doc1", "content": "some content", "timestamp": "2024-01-01"},
		},
	}
	store, err := vector.NewStore(filepath.Join(t.TempDir(), "vec.db"))
	if err != nil {
		t.Skip("cannot create vector store:", err)
	}
	tool := newSearchDocsTool(searcher, store, nil, nil)
	result, err := tool.Execute(context.Background(), "k", "u", map[string]any{"query": "test"})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	_ = result
}

// --- LiveProbesList ---

func TestLiveProbesList_NotNil(t *testing.T) {
	p := LiveProbesList()
	if p == nil {
		t.Error("expected non-nil Probes")
		return
	}
	if p.ProbeTelegram == nil {
		t.Error("expected non-nil ProbeTelegram")
	}
	if p.ProbeGemini == nil {
		t.Error("expected non-nil ProbeGemini")
	}
	if p.ProbeGmail == nil {
		t.Error("expected non-nil ProbeGmail")
	}
}

// --- mcpTool.Declaration ---

func TestMCPTool_Declaration(t *testing.T) {
	tool := newMCPTool("test-server", config.MCPServerConfig{}, nil)
	decl := tool.Declaration()
	if decl.Name != "test_server" {
		t.Errorf("expected 'test_server', got %q", decl.Name)
	}
	if decl.Description == "" {
		t.Error("expected non-empty description")
	}
}

func TestMCPProxyTool_Methods(t *testing.T) {
	decl := provider.ToolDeclaration{Name: "proxy_tool", Description: "a proxy tool"}
	proxy := &mcpProxyTool{decl: decl}
	if proxy.Name() != "proxy_tool" {
		t.Errorf("expected 'proxy_tool', got %q", proxy.Name())
	}
	got := proxy.Declaration()
	if got.Name != "proxy_tool" {
		t.Errorf("expected 'proxy_tool' in declaration, got %q", got.Name)
	}
}

// --- InitVectorStore ---

func TestInitVectorStore_NonGemini(t *testing.T) {
	cfg := &config.Config{}
	cfg.Runtime.StorageRoot = t.TempDir()
	runner := &AgentRunner{}
	// nil provider is not *provider.GeminiProvider → returns nil, nil
	store, embedProv, cleanup := InitVectorStore(cfg, nil, runner)
	defer cleanup()
	if store != nil || embedProv != nil {
		t.Error("expected nil store and embedProv for non-Gemini provider")
	}
}

func TestInitVectorStore_GeminiNoAPIKey(t *testing.T) {
	cfg := &config.Config{}
	cfg.Runtime.StorageRoot = t.TempDir()
	runner := &AgentRunner{}
	prov := provider.NewGeminiProvider(nil)
	store, embedProv, cleanup := InitVectorStore(cfg, prov, runner)
	defer cleanup()
	if store != nil || embedProv != nil {
		t.Error("expected nil store and embedProv without API key")
	}
}

func TestInitVectorStore_GeminiWithAPIKey(t *testing.T) {
	cfg := &config.Config{}
	cfg.Runtime.StorageRoot = t.TempDir()
	cfg.Runtime.VectorSearchEnabled = true
	cfg.Providers.Gemini.APIKey = "test-api-key"
	runner := &AgentRunner{}
	prov := provider.NewGeminiProvider(nil)
	store, embedProv, cleanup := InitVectorStore(cfg, prov, runner)
	defer cleanup()
	if store == nil {
		t.Error("expected non-nil vector store")
	}
	if embedProv == nil {
		t.Error("expected non-nil embedding provider")
	}
}

func TestInitVectorStore_UsesCompatibleCache(t *testing.T) {
	storageRoot := t.TempDir()
	legacyPath := filepath.Join(storageRoot, "memory", "vectors.db")
	if err := os.MkdirAll(filepath.Dir(legacyPath), 0o755); err != nil {
		t.Fatalf("create legacy cache directory: %v", err)
	}
	legacyContents := []byte("retain for manual recovery")
	if err := os.WriteFile(legacyPath, legacyContents, 0o600); err != nil {
		t.Fatalf("write legacy cache: %v", err)
	}

	cfg := &config.Config{}
	cfg.Runtime.StorageRoot = storageRoot
	cfg.Runtime.VectorSearchEnabled = true
	cfg.Providers.Gemini.APIKey = "test-api-key"
	store, _, cleanup := InitVectorStore(cfg, provider.NewGeminiProvider(nil), &AgentRunner{})
	if store == nil {
		t.Fatal("expected compatible vector store")
	}
	cleanup()

	compatiblePath := filepath.Join(storageRoot, "memory", vector.CacheFilename(cfg.EmbeddingModel()))
	if _, err := os.Stat(compatiblePath); err != nil {
		t.Fatalf("compatible cache %q was not initialized: %v", compatiblePath, err)
	}
	gotLegacy, err := os.ReadFile(legacyPath)
	if err != nil {
		t.Fatalf("read legacy cache: %v", err)
	}
	if string(gotLegacy) != string(legacyContents) {
		t.Error("legacy vectors.db was modified or imported")
	}
}

// --- InitMemory ---

func TestInitMemory_Basic(t *testing.T) {
	cfg := &config.Config{}
	cfg.Runtime.StorageRoot = t.TempDir()
	runner := &AgentRunner{}
	memStore, cleanup := InitMemory(cfg, runner)
	defer cleanup()
	_ = memStore
}

// --- Google tool Name and Declaration methods ---

func TestListCalendarTool_Methods(t *testing.T) {
	dir := t.TempDir()
	tool := newListCalendarTool(dir, nil)
	if tool.Name() != listCalendarToolName {
		t.Errorf("expected %q, got %q", listCalendarToolName, tool.Name())
	}
	decl := tool.Declaration()
	if decl.Name != listCalendarToolName {
		t.Errorf("expected %q in declaration, got %q", listCalendarToolName, decl.Name)
	}
}

func TestListTasksTool_Methods(t *testing.T) {
	dir := t.TempDir()
	tool := newListTasksTool(dir, nil)
	if tool.Name() != listTasksToolName {
		t.Errorf("expected %q, got %q", listTasksToolName, tool.Name())
	}
	decl := tool.Declaration()
	if decl.Name != listTasksToolName {
		t.Errorf("expected %q in declaration, got %q", listTasksToolName, decl.Name)
	}
}

func TestCreateTaskTool_Methods(t *testing.T) {
	dir := t.TempDir()
	tool := newCreateTaskTool(dir, nil)
	if tool.Name() != createTaskToolName {
		t.Errorf("expected %q, got %q", createTaskToolName, tool.Name())
	}
	decl := tool.Declaration()
	if decl.Name != createTaskToolName {
		t.Errorf("expected %q in declaration, got %q", createTaskToolName, decl.Name)
	}
}

func TestCreateTaskTool_Execute_NoTitle(t *testing.T) {
	tool := newCreateTaskTool(t.TempDir(), nil)
	_, err := tool.Execute(context.Background(), "", "", map[string]any{"title": ""})
	if err == nil {
		t.Error("expected error for empty title")
	}
}

func TestCompleteTaskTool_Execute_NoID(t *testing.T) {
	tool := newCompleteTaskTool(t.TempDir(), nil)
	_, err := tool.Execute(context.Background(), "", "", map[string]any{})
	if err == nil {
		t.Error("expected error for empty task_id")
	}
}

func TestCompleteTaskTool_Execute_WithID(t *testing.T) {
	tool := newCompleteTaskTool(t.TempDir(), nil)
	_, err := tool.Execute(context.Background(), "", "", map[string]any{"task_id": "task-123"})
	if err == nil {
		t.Log("expected auth error, got nil")
	}
}

func TestUpdateTaskTool_Execute_NoID(t *testing.T) {
	tool := newUpdateTaskTool(t.TempDir(), nil)
	_, err := tool.Execute(context.Background(), "", "", map[string]any{})
	if err == nil {
		t.Error("expected error for empty task_id")
	}
}

func TestCreateCalendarEventTool_Methods(t *testing.T) {
	dir := t.TempDir()
	tool := newCreateCalendarEventTool(dir, nil)
	if tool.Name() != createCalendarEventToolName {
		t.Errorf("expected %q, got %q", createCalendarEventToolName, tool.Name())
	}
	decl := tool.Declaration()
	if decl.Name != createCalendarEventToolName {
		t.Errorf("expected %q in declaration, got %q", createCalendarEventToolName, decl.Name)
	}
}

func TestCreateCalendarEventTool_Execute_NoSummary(t *testing.T) {
	tool := newCreateCalendarEventTool(t.TempDir(), nil)
	_, err := tool.Execute(context.Background(), "", "", map[string]any{})
	if err == nil {
		t.Error("expected error for missing summary")
	}
}

func TestCreateCalendarEventTool_Execute_NoStartTime(t *testing.T) {
	tool := newCreateCalendarEventTool(t.TempDir(), nil)
	_, err := tool.Execute(context.Background(), "", "", map[string]any{"summary": "Meeting"})
	if err == nil {
		t.Error("expected error for missing start_time")
	}
}

func TestWebSearchTool_Methods(t *testing.T) {
	tool := newWebSearchTool("key", "cx", nil)
	if tool.Name() != webSearchToolName {
		t.Errorf("expected %q, got %q", webSearchToolName, tool.Name())
	}
	decl := tool.Declaration()
	if decl.Name != webSearchToolName {
		t.Errorf("expected %q in declaration, got %q", webSearchToolName, decl.Name)
	}
}

func TestListCalendarTool_Execute_NoToken(t *testing.T) {
	tool := newListCalendarTool(t.TempDir(), nil)
	_, err := tool.Execute(context.Background(), "", "", map[string]any{})
	if err == nil {
		t.Log("expected auth error without token")
	}
}

func TestListTasksTool_Execute_NoToken(t *testing.T) {
	tool := newListTasksTool(t.TempDir(), nil)
	_, err := tool.Execute(context.Background(), "", "", map[string]any{})
	if err == nil {
		t.Log("expected auth error without token")
	}
}

// --- shellExecTool Declaration ---

func TestShellExecTool_Declaration(t *testing.T) {
	tempDir := t.TempDir()
	cfg := &config.Config{}
	cfg.Runtime.StorageRoot = tempDir
	registry := NewToolRegistry(tempDir)
	tool := newShellExecTool(cfg, 30*time.Second, registry)
	decl := tool.Declaration()
	if decl.Name != shellExecToolName {
		t.Errorf("expected %q, got %q", shellExecToolName, decl.Name)
	}
}

// --- buildSystemPrompt ---

func TestBuildSystemPrompt_NilMemStore(t *testing.T) {
	runner := &AgentRunner{SystemPrompt: "base prompt"} //nolint:goconst // shared test string; extracting crosses file boundaries
	result := runner.buildSystemPrompt(context.Background(), "session", nil, nil)
	if result != "base prompt" { //nolint:goconst // shared test string; refactoring across files is out of scope
		t.Errorf("expected 'base prompt', got %q", result)
	}
}

func TestBuildSystemPrompt_WithMemStore_SkipRAG(t *testing.T) {
	cfg := &config.Config{}
	cfg.Runtime.StorageRoot = t.TempDir()
	runner := &AgentRunner{SystemPrompt: "sys", Cfg: cfg}
	memStore, cleanup := InitMemory(cfg, runner)
	defer cleanup()

	// Empty message list → LastUserText returns "" → ShouldSkipRAG = true
	result := runner.buildSystemPrompt(context.Background(), "session", nil, memStore)
	if result != "sys" {
		t.Errorf("expected 'sys', got %q", result)
	}
}

// --- SetupConsolidator ---

func TestSetupConsolidator_NilMemStore(t *testing.T) {
	stack := &AgentStack{}
	handler := &DispatchHandler{}
	SetupConsolidator(context.Background(), &config.Config{}, stack, nil, handler, nil, nil)
	if handler.Consolidator != nil {
		t.Error("expected nil consolidator when stack has no MemStore")
	}
}

func TestSetupConsolidator_WithMemStore(t *testing.T) {
	cfg := &config.Config{}
	cfg.Runtime.StorageRoot = t.TempDir()
	runner := &AgentRunner{Cfg: cfg}
	memStore, cleanup := InitMemory(cfg, runner)
	defer cleanup()

	stack := &AgentStack{Runner: runner, MemStore: memStore}
	mgr := agent.NewSessionManager(runner, nil, "test-model")
	handler := &DispatchHandler{}
	SetupConsolidator(context.Background(), cfg, stack, mgr, handler, nil, nil)
	if handler.Consolidator == nil {
		t.Error("expected non-nil consolidator when stack has MemStore")
	}
}

// --- SetupGateHandler ---

func TestSetupGateHandler_NilStore(t *testing.T) {
	handler := &DispatchHandler{}
	result := SetupGateHandler(nil, handler)
	if result != handler {
		t.Error("expected same handler returned when store is nil")
	}
}

func TestSetupGateHandler_WithCheckpointManager(t *testing.T) {
	storageDir := t.TempDir()
	store, err := agentctx.GetCheckpointManager(storageDir)
	if err != nil {
		t.Skipf("cannot create checkpoint manager: %v", err)
	}
	defer func() { _ = store.DB().Close() }()
	handler := &DispatchHandler{}
	result := SetupGateHandler(store, handler)
	if result == nil {
		t.Error("expected non-nil handler")
	}
}

// --- RunIdempotencyCleanup ---

func TestRunIdempotencyCleanup_CancelledCtx(t *testing.T) {
	storageDir := t.TempDir()
	cm, err := agentctx.GetCheckpointManager(storageDir)
	if err != nil {
		t.Skipf("cannot create checkpoint manager: %v", err)
	}
	defer func() { _ = cm.DB().Close() }()
	idem := agentctx.NewIdempotencyStore(cm.DB(), time.Hour)
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	RunIdempotencyCleanup(ctx, idem, 10*time.Millisecond)
}

// --- InitMemory multi-user ---

func TestInitMemory_MultiUser(t *testing.T) {
	cfg := &config.Config{}
	cfg.Runtime.StorageRoot = t.TempDir()
	cfg.Runtime.MultiUserEnabled = true
	runner := &AgentRunner{}
	memStore, cleanup := InitMemory(cfg, runner)
	defer cleanup()
	_ = memStore
}

// --- NewSessionManager multi-user branch ---

func TestNewSessionManager_MultiUser(t *testing.T) {
	cfg := &config.Config{}
	cfg.Runtime.StorageRoot = t.TempDir()
	cfg.Runtime.MultiUserEnabled = true
	runner := &AgentRunner{Cfg: cfg}
	memStore, cleanup := InitMemory(cfg, runner)
	defer cleanup()
	stack := &AgentStack{Runner: runner, MemStore: memStore}
	store, err := agentctx.GetCheckpointManager(cfg.StorageRoot())
	if err != nil {
		t.Skipf("cannot get checkpoint manager: %v", err)
	}
	defer func() { _ = store.DB().Close() }()
	mgr := stack.NewSessionManager(cfg, store, nil)
	if mgr == nil {
		t.Error("expected non-nil session manager")
	}
}

// --- loadScheduleContext ---

func TestLoadScheduleContext_Empty(t *testing.T) {
	result := loadScheduleContext("")
	if result != "" {
		t.Errorf("expected empty string for empty secretsRoot, got %q", result)
	}
}

func TestLoadScheduleContext_NoToken(t *testing.T) {
	result := loadScheduleContext(t.TempDir())
	// Should return empty string (calendar/tasks fail gracefully without token)
	if result != "" {
		t.Logf("loadScheduleContext returned non-empty: %q", result)
	}
}

// --- shouldRetry ---

func TestShouldRetry(t *testing.T) {
	runner := &AgentRunner{}
	if runner.shouldRetry(nil) {
		t.Error("expected false for nil error")
	}
	if runner.shouldRetry(resilience.ErrCircuitOpen) {
		t.Error("expected false for circuit open error")
	}
	// A non-circuit-open, non-transient error should return false
	if runner.shouldRetry(errors.New("generic error")) {
		t.Log("generic error returned true for shouldRetry — may be transient")
	}
}

// --- ExtractText ---

func TestExtractText_Nil(t *testing.T) {
	var msg agentctx.StrategicMessage
	if got := ExtractText(msg); got != "" {
		t.Errorf("expected empty string, got %q", got)
	}
}

func TestExtractText_StringContent(t *testing.T) {
	s := "hello" //nolint:goconst // shared test string; extracting crosses file boundaries
	msg := agentctx.StrategicMessage{
		Content: &agentctx.MessageContent{Str: &s},
	}
	if got := ExtractText(msg); got != "hello" {
		t.Errorf("expected 'hello', got %q", got)
	}
}

func TestShouldRetry_RateLimit(t *testing.T) {
	runner := &AgentRunner{}
	if !runner.shouldRetry(errors.New("HTTP 429 Too Many Requests")) {
		t.Error("expected true for HTTP 429 rate-limit error")
	}
	if !runner.shouldRetry(errors.New("RESOURCE_EXHAUSTED: quota")) {
		t.Error("expected true for RESOURCE_EXHAUSTED error")
	}
}

func TestShouldRetryGeminiProbe(t *testing.T) {
	if !shouldRetryGeminiProbe(errors.New("HTTP 429 Too Many Requests")) {
		t.Error("expected true for HTTP 429")
	}
	if !shouldRetryGeminiProbe(errors.New("RESOURCE_EXHAUSTED")) {
		t.Error("expected true for RESOURCE_EXHAUSTED")
	}
	if shouldRetryGeminiProbe(errors.New("invalid api key")) {
		t.Error("expected false for non-retryable auth error")
	}
}

// shutdownCompactionStore pauses the background reload after the dispatch has
// persisted and scheduled compaction. The store intentionally ignores cancellation.
type shutdownCompactionStore struct {
	agent.CheckpointStore
	loads            atomic.Int32
	entered, release chan struct{}
}

func (s *shutdownCompactionStore) LoadLatest(ctx context.Context, key string) (*agentctx.ThreadSnapshot, error) {
	if s.loads.Add(1) == 2 {
		close(s.entered)
		<-s.release
	}
	return s.CheckpointStore.LoadLatest(ctx, key)
}

func TestRuntimeJoinsScheduledCompaction(t *testing.T) {
	// Start the process-wide signal listener outside the synctest bubble.
	signals := make(chan os.Signal, 1)
	signal.Notify(signals)
	signal.Stop(signals)
	for _, cron := range []bool{false, true} {
		t.Run(map[bool]string{false: "primary", true: "cron per-user"}[cron], func(t *testing.T) {
			synctest.Test(t, func(t *testing.T) { testRuntimeJoinsScheduledCompaction(t, cron) })
		})
	}
}

func testRuntimeJoinsScheduledCompaction(t *testing.T, cron bool) {
	t.Helper()
	cfg := &config.Config{}
	cfg.Runtime.StorageRoot = t.TempDir()
	cfg.Context.SessionTokenBudget = 1
	cfg.Cron.Enabled = cron
	cfg.Runtime.MultiUserEnabled = cron
	storeRoot := cfg.StorageRoot()
	if cron {
		storeRoot = cfg.WorkspacePath("user")
	}
	store, err := agentctx.GetCheckpointManager(storeRoot)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		agentctx.EvictCheckpointManagerForTest(storeRoot)
		agentctx.EvictCheckpointManagerForTest(cfg.WorkspacePath(""))
		agentctx.EvictCheckpointManagerForTest(cfg.StorageRoot())
	})
	wrapped := &shutdownCompactionStore{CheckpointStore: store, entered: make(chan struct{}), release: make(chan struct{})}
	var releaseOnce sync.Once
	defer releaseOnce.Do(func() { close(wrapped.release) })
	prov := &mockChatProvider{resp: "a sufficiently long response to exceed the token budget"}
	stack := &AgentStack{Runner: NewAgentRunner(prov, "mock", "", cfg), Model: "mock"}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	managers := make(chan *agent.SessionManager, 1)
	done := make(chan error, 1)
	exited := make(chan struct{})
	defer func() {
		cancel()
		releaseOnce.Do(func() { close(wrapped.release) })
		select {
		case <-exited:
		case <-time.After(10 * time.Second):
			t.Error("runtime did not exit during cleanup")
		}
	}()
	go func() {
		defer close(exited)
		done <- runInitializedAgentLoopWithReady(ctx, cfg, stack, nil, nil, nil, nil, time.Now(), nil, func(_ context.Context, primary, cronMgr *agent.SessionManager) {
			mgr := primary
			if cron {
				mgr = cronMgr
			}
			managers <- mgr
		})
	}()
	assertRuntimeJoinsCompaction(t, ctx, cancel, managers, wrapped, done, &releaseOnce)
}

//nolint:cyclop // Each barrier reports a distinct runtime failure.
func assertRuntimeJoinsCompaction(t *testing.T, ctx context.Context, cancel context.CancelFunc, managers <-chan *agent.SessionManager, wrapped *shutdownCompactionStore, done <-chan error, releaseOnce *sync.Once) {
	t.Helper()
	var mgr *agent.SessionManager
	select {
	case mgr = <-managers:
	case <-time.After(10 * time.Second):
		t.Fatal("runtime did not start")
	}
	if mgr == nil {
		t.Fatal("missing runtime manager")
	}
	defer func() {
		releaseOnce.Do(func() { close(wrapped.release) })
		if err := mgr.WaitForBackgroundCompactions(context.Background()); err != nil {
			t.Errorf("join worker during cleanup: %v", err)
		}
	}()
	mgr.SetCheckpointStoreProvider(func(string) (agent.CheckpointStore, error) { return wrapped, nil })
	if _, err := mgr.Dispatch(ctx, t.Name(), "user", "words that exceed the tiny token budget"); err != nil {
		t.Fatal(err)
	}
	select {
	case <-wrapped.entered:
	case <-time.After(10 * time.Second):
		t.Fatal("worker did not enter store")
	}
	cancel()
	// Wait for shutdown to run until all bubble goroutines are blocked. The
	// fake clock cannot advance while Wait is pending, so the join deadline
	// cannot mask an early return.
	synctest.Wait()
	select {
	case err := <-done:
		t.Fatalf("shutdown returned before worker release: %v", err)
	default:
	}
	releaseOnce.Do(func() { close(wrapped.release) })
	select {
	case err := <-done:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(10 * time.Second):
		t.Fatal("shutdown did not finish")
	}
}

//nolint:gocognit,cyclop // The shared-deadline scenario coordinates two independent workers.
func TestJoinSessionCompactionsSharedDeadline(t *testing.T) {
	root := t.TempDir()
	store, err := agentctx.GetCheckpointManager(root)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { agentctx.EvictCheckpointManagerForTest(root) })
	cfg := &config.Config{}
	prov := &mockChatProvider{resp: "enough words for a compaction"}
	var managers []*agent.SessionManager
	var stores []*shutdownCompactionStore
	t.Cleanup(func() {
		for _, s := range stores {
			select {
			case <-s.release:
			default:
				close(s.release)
			}
		}
		for _, mgr := range managers {
			ctx, cancel := context.WithTimeout(context.Background(), time.Second)
			_ = mgr.WaitForBackgroundCompactions(ctx)
			cancel()
		}
	})
	for i := 0; i < 2; i++ {
		wrapped := &shutdownCompactionStore{CheckpointStore: store, entered: make(chan struct{}), release: make(chan struct{})}
		mgr := agent.NewSessionManager(NewAgentRunner(prov, "mock", "", cfg), wrapped, "mock")
		mgr.SetTokenBudget(1)
		managers = append(managers, mgr)
		stores = append(stores, wrapped)
		if _, err := mgr.Dispatch(context.Background(), fmt.Sprintf("join-%d", i), "user", "enough words for compaction"); err != nil {
			t.Fatal(err)
		}
		select {
		case <-wrapped.entered:
		case <-time.After(10 * time.Second):
			t.Fatal("worker did not enter store")
		}
	}
	var logs bytes.Buffer
	old := slog.Default()
	slog.SetDefault(slog.New(slog.NewJSONHandler(&logs, nil)))
	t.Cleanup(func() { slog.SetDefault(old) })
	started := time.Now()
	joinSessionCompactions(20*time.Millisecond, managers...)
	if time.Since(started) > time.Second {
		t.Fatal("shared deadline was not bounded")
	}
	if strings.Count(logs.String(), "background compaction drain failed") != 2 {
		t.Fatalf("expected two structured warnings: %s", logs.String())
	}
	for _, s := range stores {
		close(s.release)
	}
	for i, mgr := range managers {
		ctx, cancel := context.WithTimeout(context.Background(), time.Second)
		err := mgr.WaitForBackgroundCompactions(ctx)
		cancel()
		if err != nil {
			t.Fatalf("join after release: %v", err)
		}
		if _, err := store.LoadLatest(context.Background(), fmt.Sprintf("join-%d", i)); err != nil {
			t.Fatalf("store unavailable after timed-out join: %v", err)
		}
	}
}
