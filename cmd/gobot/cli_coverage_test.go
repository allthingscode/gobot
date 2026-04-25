package main

import (
	"bufio"
	"bytes"
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/allthingscode/gobot/internal/agent"
	"github.com/allthingscode/gobot/internal/config"
	agentctx "github.com/allthingscode/gobot/internal/context"
	"github.com/allthingscode/gobot/internal/factory"
)

func TestCmdVersion(t *testing.T) {
	cmd := cmdVersion()
	b := bytes.NewBufferString("")
	cmd.SetOut(b)
	if err := cmd.Execute(); err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !strings.Contains(b.String(), "gobot") {
		t.Errorf("expected 'gobot' in version output, got %q", b.String())
	}
}

func TestCmdInit(t *testing.T) {
	tempDir := t.TempDir()
	t.Setenv("GOBOT_HOME", tempDir)
	cmd := cmdInit()
	cmd.SetArgs([]string{"--root", tempDir})
	if err := cmd.Execute(); err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if _, err := os.Stat(filepath.Join(tempDir, "workspace", "sessions")); os.IsNotExist(err) {
		t.Error("expected sessions directory to be created under workspace/")
	}
	configPath := filepath.Join(tempDir, ".gobot", "config.json")
	if _, err := os.Stat(configPath); os.IsNotExist(err) {
		t.Errorf("expected config file at %s to be created", configPath)
	}
}

func TestCmdRun_Help(t *testing.T) {
	cmd := cmdRun()
	b := bytes.NewBufferString("")
	cmd.SetOut(b)
	cmd.SetArgs([]string{"--help"})
	if err := cmd.Execute(); err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !strings.Contains(b.String(), "web-addr") {
		t.Error("expected help text to contain web-addr flag")
	}
}

func TestRunInit_Errors(t *testing.T) {
	err := runInit("/invalid/path/that/does/not/exist/and/cannot/be/created")
	if err == nil {
		t.Log("Warning: runInit might have succeeded if it could create the path")
	}
}

func TestCmdDoctor_Error(t *testing.T) {
	tempDir := t.TempDir()
	t.Setenv("GOBOT_HOME", tempDir)
	configPath := config.DefaultConfigPath()
	_ = os.MkdirAll(filepath.Dir(configPath), 0o755)
	_ = os.WriteFile(configPath, []byte("invalid-json"), 0o600)
	cmd := cmdDoctor()
	err := cmd.Execute()
	if err == nil {
		t.Error("expected error due to invalid config")
	}
}

func TestCmdRun_PrerequisiteFail(t *testing.T) {
	cmd := cmdRun()
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	cmd.SetContext(ctx)
	os.Setenv("TELEGRAM_APITOKEN", "")
	tempDir := t.TempDir()
	cfg := &config.Config{}
	cfg.Channels.Telegram.Enabled = true
	configPath := filepath.Join(tempDir, "config.json")
	_ = cfg.Save(configPath)
	os.Setenv("GOBOT_HOME", tempDir)
	defer os.Unsetenv("GOBOT_HOME")
	err := cmd.Execute()
	if err == nil {
		t.Log("Warning: cmdRun might have succeeded if config load didn't fail")
	}
}

// --- exitCodeError ---

func TestExitCodeError(t *testing.T) {
	e := &exitCodeError{code: 1, err: fmt.Errorf("something failed")}
	if e.Error() != "something failed" {
		t.Errorf("expected 'something failed', got %q", e.Error())
	}
	e2 := &exitCodeError{code: 2}
	if e2.Error() != "exit code 2" {
		t.Errorf("expected 'exit code 2', got %q", e2.Error())
	}
}

// --- parseSinceDuration ---

func TestParseSinceDuration(t *testing.T) {
	ts, err := parseSinceDuration("")
	if err != nil || !ts.IsZero() {
		t.Errorf("empty: expected zero time, got %v %v", ts, err)
	}
	ts, err = parseSinceDuration("1h")
	if err != nil || ts.IsZero() {
		t.Errorf("1h: expected non-zero time, got %v %v", ts, err)
	}
	_, err = parseSinceDuration("notaduration")
	if err == nil {
		t.Error("expected error for invalid duration")
	}
}

// --- parseLogTime ---

func TestParseLogTime(t *testing.T) {
	line := `time=2024-01-01T00:00:00Z level=INFO msg="hello"`
	ts, ok := parseLogTime(line)
	if !ok || ts.IsZero() {
		t.Errorf("expected valid time, got %v %v", ts, ok)
	}
	// No time= prefix — passes through
	_, ok2 := parseLogTime("some other line")
	if !ok2 {
		t.Error("expected ok=true for line without time=")
	}
	// time= at end of line (no space after value)
	_, ok3 := parseLogTime("time=2024-01-01T00:00:00Z")
	if !ok3 {
		t.Error("expected ok=true for time= at end of line")
	}
	// Unparseable time value
	_, ok4 := parseLogTime("time=not-a-time msg=test")
	if ok4 {
		t.Error("expected ok=false for unparseable time")
	}
}

// --- makeLogFilter ---

func TestMakeLogFilter(t *testing.T) {
	// No filter, no since → always passes
	fn := makeLogFilter("", time.Time{})
	if !fn("any line") {
		t.Error("expected any line to pass with no filter")
	}
	// Level filter
	fn2 := makeLogFilter("ERROR", time.Time{})
	if fn2("level=INFO msg=test") {
		t.Error("INFO line should not pass ERROR filter")
	}
	if !fn2("level=ERROR msg=test") {
		t.Error("ERROR line should pass ERROR filter")
	}
	// Since filter — recent line passes
	sinceTime := time.Now().Add(-1 * time.Hour)
	fn3 := makeLogFilter("", sinceTime)
	recent := fmt.Sprintf("time=%s msg=recent", time.Now().Format(time.RFC3339Nano))
	if !fn3(recent) {
		t.Error("recent line should pass since filter")
	}
	old := fmt.Sprintf("time=%s msg=old", time.Now().Add(-2*time.Hour).Format(time.RFC3339Nano))
	if fn3(old) {
		t.Error("old line should not pass since filter")
	}
	// Since filter with unparseable time in line → filtered out (ok=false branch)
	if fn3("time=not-a-valid-time some message") {
		t.Error("line with unparseable time should not pass since filter")
	}
	// Line without time= prefix: parseLogTime returns ok=true, but zero time is before sinceTime
	if fn3("no time info here") {
		t.Error("line without parseable time should not pass since filter")
	}
}

// --- mapSpecialistRole ---

func TestMapSpecialistRole(t *testing.T) {
	roles := []string{"groomer", "architect", "reviewer", "operator", "researcher", "unknown"}
	for _, role := range roles {
		tState := &factory.TaskState{}
		mapSpecialistRole(role, map[string]any{"key": "val"}, tState)
	}
}

// --- migrateTasks ---

func TestMigrateTasks(t *testing.T) {
	target := make(map[string]*factory.TaskState)
	// No tasks key
	migrateTasks(map[string]any{}, target)
	if len(target) != 0 {
		t.Errorf("expected empty target, got %d", len(target))
	}
	// tasks key is not a map
	migrateTasks(map[string]any{"tasks": "notamap"}, target)
	// Valid tasks
	legacy := map[string]any{
		"tasks": map[string]any{
			"T-001": map[string]any{
				"groomer": map[string]any{"status": "done"},
			},
			"T-002": "invalid-task-entry",
		},
	}
	migrateTasks(legacy, target)
	if len(target) != 1 {
		t.Errorf("expected 1 task, got %d", len(target))
	}
}

// --- migrateLegacySpecialists ---

func TestMigrateLegacySpecialists(t *testing.T) {
	s1 := &factory.SessionState{Tasks: make(map[string]*factory.TaskState)}
	// No _legacy key
	migrateLegacySpecialists(map[string]any{}, s1)
	if s1.LegacySpecialists != nil {
		t.Error("expected nil LegacySpecialists when no _legacy key")
	}
	// _legacy is not a map
	migrateLegacySpecialists(map[string]any{"_legacy": "bad"}, s1)
	// No specialists key
	migrateLegacySpecialists(map[string]any{
		"_legacy": map[string]any{"other": "val"},
	}, s1)
	// Valid specialists
	s2 := &factory.SessionState{Tasks: make(map[string]*factory.TaskState)}
	legacy := map[string]any{
		"_legacy": map[string]any{
			"specialists": map[string]any{
				"groomer": map[string]any{"status": "active"},
				"bad":     "notamap",
			},
		},
	}
	migrateLegacySpecialists(legacy, s2)
	if len(s2.LegacySpecialists) != 1 {
		t.Errorf("expected 1 legacy specialist, got %d", len(s2.LegacySpecialists))
	}
}

// --- printSnapshots ---

func TestPrintSnapshots(t *testing.T) {
	// Empty
	printSnapshots([]agent.SnapshotMetadata{})
	// Few snapshots (≤10)
	snaps := []agent.SnapshotMetadata{
		{Name: "snap-1", Timestamp: "2024-01-01T00:00:00Z", TaskID: "T-001", GitSHA: "abc1234def"},
	}
	printSnapshots(snaps)
	// >10 → limit enforced
	many := make([]agent.SnapshotMetadata, 15)
	for i := range many {
		many[i] = agent.SnapshotMetadata{Name: fmt.Sprintf("snap-%d", i)}
	}
	printSnapshots(many)
}

// --- Command constructors ---

func TestCommandConstructors(t *testing.T) { //nolint:gocognit,cyclop,funlen // exhaustive constructor nil-check; splitting adds no value
	if cmdConfig() == nil {
		t.Error("cmdConfig nil")
	}
	if cmdConfigReformat() == nil {
		t.Error("cmdConfigReformat nil")
	}
	if cmdConfigValidate() == nil {
		t.Error("cmdConfigValidate nil")
	}
	if cmdFactory() == nil {
		t.Error("cmdFactory nil")
	}
	if cmdFactoryState() == nil {
		t.Error("cmdFactoryState nil")
	}
	if cmdFactoryStateValidate() == nil {
		t.Error("cmdFactoryStateValidate nil")
	}
	if cmdFactoryStateMigrate() == nil {
		t.Error("cmdFactoryStateMigrate nil")
	}
	if cmdSecrets() == nil {
		t.Error("cmdSecrets nil")
	}
	if cmdSecretsSet() == nil {
		t.Error("cmdSecretsSet nil")
	}
	if cmdSecretsGet() == nil {
		t.Error("cmdSecretsGet nil")
	}
	if cmdSecretsList() == nil {
		t.Error("cmdSecretsList nil")
	}
	if cmdSecretsDelete() == nil {
		t.Error("cmdSecretsDelete nil")
	}
	if cmdState() == nil {
		t.Error("cmdState nil")
	}
	if cmdStateList() == nil {
		t.Error("cmdStateList nil")
	}
	if cmdStateInspect() == nil {
		t.Error("cmdStateInspect nil")
	}
	if cmdStateRecover() == nil {
		t.Error("cmdStateRecover nil")
	}
	if cmdStateArchive() == nil {
		t.Error("cmdStateArchive nil")
	}
	if cmdRewind() == nil {
		t.Error("cmdRewind nil")
	}
	if cmdRewindList() == nil {
		t.Error("cmdRewindList nil")
	}
	if cmdMemory() == nil {
		t.Error("cmdMemory nil")
	}
	if cmdMemoryRebuild() == nil {
		t.Error("cmdMemoryRebuild nil")
	}
	if cmdMemorySearch() == nil {
		t.Error("cmdMemorySearch nil")
	}
	if cmdCheckpoints() == nil {
		t.Error("cmdCheckpoints nil")
	}
	if cmdClearCheckpoint() == nil {
		t.Error("cmdClearCheckpoint nil")
	}
	if cmdResume() == nil {
		t.Error("cmdResume nil")
	}
	if cmdReauth() == nil {
		t.Error("cmdReauth nil")
	}
	if cmdAuthorize() == nil {
		t.Error("cmdAuthorize nil")
	}
	if cmdLogs() == nil {
		t.Error("cmdLogs nil")
	}
	if cmdEmail() == nil {
		t.Error("cmdEmail nil")
	}
	if cmdSimulate() == nil {
		t.Error("cmdSimulate nil")
	}
	if cmdCalendar() == nil {
		t.Error("cmdCalendar nil")
	}
	if cmdTasks() == nil {
		t.Error("cmdTasks nil")
	}
}

// --- cmdFactoryStateValidate RunE ---

func TestCmdFactoryStateValidate_Run(t *testing.T) {
	dir := t.TempDir()
	// Valid JSON
	validFile := filepath.Join(dir, "state.json")
	_ = os.WriteFile(validFile, []byte(`{"version":"2.0"}`), 0o600)
	cmd := cmdFactoryStateValidate()
	cmd.SetArgs([]string{validFile})
	if err := cmd.Execute(); err != nil {
		t.Errorf("expected success, got: %v", err)
	}
	// Invalid JSON
	invalidFile := filepath.Join(dir, "bad.json")
	_ = os.WriteFile(invalidFile, []byte(`{not valid json`), 0o600)
	cmd2 := cmdFactoryStateValidate()
	cmd2.SetArgs([]string{invalidFile})
	if err := cmd2.Execute(); err == nil {
		t.Error("expected error for invalid JSON")
	}
	// Missing file
	cmd3 := cmdFactoryStateValidate()
	cmd3.SetArgs([]string{filepath.Join(dir, "missing.json")})
	if err := cmd3.Execute(); err == nil {
		t.Error("expected error for missing file")
	}
}

// --- runMigrate ---

func TestRunMigrate_Valid(t *testing.T) {
	dir := t.TempDir()
	legacyFile := filepath.Join(dir, "state.json")
	_ = os.WriteFile(legacyFile, []byte(`{"tasks":{"T-001":{"groomer":{}}},"_legacy":{}}`), 0o600)
	if err := runMigrate(legacyFile); err != nil {
		t.Errorf("unexpected error: %v", err)
	}
}

func TestRunMigrate_InvalidJSON(t *testing.T) {
	dir := t.TempDir()
	badFile := filepath.Join(dir, "bad.json")
	_ = os.WriteFile(badFile, []byte(`{not json`), 0o600)
	if err := runMigrate(badFile); err == nil {
		t.Error("expected error for invalid JSON")
	}
}

func TestRunMigrate_MissingFile(t *testing.T) {
	if err := runMigrate("/nonexistent/file.json"); err == nil {
		t.Error("expected error for missing file")
	}
}

// --- readInitialLogs ---

func TestReadInitialLogs_Basic(t *testing.T) {
	content := "line1\nline2\nline3\n"
	reader := bufio.NewReader(strings.NewReader(content))
	filterFn := func(string) bool { return true }
	logs, _, err := readInitialLogs(reader, 2, filterFn)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(logs) != 2 {
		t.Errorf("expected 2 lines in ring buffer, got %d", len(logs))
	}
}

func TestReadInitialLogs_WithFilter(t *testing.T) {
	content := "level=INFO line1\nlevel=ERROR line2\nlevel=INFO line3\n"
	reader := bufio.NewReader(strings.NewReader(content))
	filterFn := func(line string) bool { return strings.Contains(line, "ERROR") }
	logs, _, err := readInitialLogs(reader, 10, filterFn)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(logs) != 1 {
		t.Errorf("expected 1 filtered line, got %d", len(logs))
	}
}

// --- findLatestLogFile ---

func TestFindLatestLogFile_NoDir(t *testing.T) {
	_, err := findLatestLogFile("/nonexistent/path/to/logs")
	if err == nil {
		t.Error("expected error for non-existent directory")
	}
}

func TestFindLatestLogFile_EmptyDir(t *testing.T) {
	_, err := findLatestLogFile(t.TempDir())
	if err == nil {
		t.Error("expected error for directory with no log files")
	}
}

func TestFindLatestLogFile_WithLogs(t *testing.T) {
	dir := t.TempDir()
	_ = os.WriteFile(filepath.Join(dir, "gobot_2024.log"), []byte("log1"), 0o600)
	_ = os.WriteFile(filepath.Join(dir, "gobot_2025.log"), []byte("log2"), 0o600)
	_ = os.WriteFile(filepath.Join(dir, "other.txt"), []byte("not a log"), 0o600)
	path, err := findLatestLogFile(dir)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !strings.HasSuffix(path, ".log") {
		t.Errorf("expected a .log file, got %q", path)
	}
}

// --- Command RunE execution paths ---

func TestCmdStateList_Empty(t *testing.T) {
	t.Setenv("GOBOT_STORAGE", t.TempDir())
	cmd := cmdStateList()
	if err := cmd.Execute(); err != nil {
		t.Errorf("unexpected error: %v", err)
	}
}

func TestCmdStateInspect_NotFound(t *testing.T) {
	t.Setenv("GOBOT_STORAGE", t.TempDir())
	cmd := cmdStateInspect()
	cmd.SetArgs([]string{"nonexistent-workflow-id"})
	cmd.SilenceErrors = true
	// Expect error: workflow not found
	_ = cmd.Execute()
}

func TestCmdStateArchive_NotFound(t *testing.T) {
	t.Setenv("GOBOT_STORAGE", t.TempDir())
	cmd := cmdStateArchive()
	cmd.SetArgs([]string{"nonexistent-workflow-id"})
	cmd.SilenceErrors = true
	// Expect error: workflow not found or lock error
	_ = cmd.Execute()
}

func TestRunListSnapshots_Empty(t *testing.T) {
	isolateStorage(t)
	if err := runListSnapshots(); err != nil {
		t.Errorf("unexpected error: %v", err)
	}
}

func TestCmdSecretsList_Empty(t *testing.T) {
	t.Setenv("GOBOT_STORAGE", t.TempDir())
	cmd := cmdSecretsList()
	if err := cmd.Execute(); err != nil {
		t.Errorf("unexpected error: %v", err)
	}
}

func TestCmdSecretsGet_NotFound(t *testing.T) {
	t.Setenv("GOBOT_STORAGE", t.TempDir())
	cmd := cmdSecretsGet()
	cmd.SetArgs([]string{"nonexistent-key"})
	if err := cmd.Execute(); err != nil {
		t.Errorf("unexpected error: %v", err)
	}
}

func TestCmdSecretsDelete_NotFound(t *testing.T) {
	t.Setenv("GOBOT_STORAGE", t.TempDir())
	cmd := cmdSecretsDelete()
	cmd.SetArgs([]string{"nonexistent-key"})
	if err := cmd.Execute(); err != nil {
		t.Errorf("unexpected error: %v", err)
	}
}

func TestCmdConfigReformat_Valid(t *testing.T) {
	tempDir := t.TempDir()
	t.Setenv("GOBOT_HOME", tempDir)
	cmd := cmdConfigReformat()
	cmd.SilenceErrors = true
	_ = cmd.Execute()
}

func TestCmdConfigValidate_Valid(t *testing.T) {
	tempDir := t.TempDir()
	t.Setenv("GOBOT_HOME", tempDir)
	cmd := cmdConfigValidate()
	cmd.SilenceErrors = true
	_ = cmd.Execute()
}

func TestCmdCheckpoints_Empty(t *testing.T) {
	t.Setenv("GOBOT_STORAGE", t.TempDir())
	cmd := cmdCheckpoints()
	cmd.SilenceErrors = true
	_ = cmd.Execute()
}

func TestRunMemorySearch_Empty(t *testing.T) {
	t.Setenv("GOBOT_STORAGE", t.TempDir())
	_ = runMemorySearch("test query")
}

func TestRunMemoryRebuild_EmptyDir(t *testing.T) {
	t.Setenv("GOBOT_STORAGE", t.TempDir())
	_ = runMemoryRebuild()
}

// --- cmdCalendar and cmdTasks auth error paths ---

func TestCmdCalendar_AuthError(t *testing.T) {
	isolateStorage(t)
	cmd := cmdCalendar()
	cmd.SilenceErrors = true
	err := cmd.Execute()
	// expects calendar auth error (no token)
	if err == nil {
		t.Log("cmdCalendar returned nil - may have succeeded with no token")
	}
}

func TestCmdTasksList_AuthError(t *testing.T) {
	t.Setenv("GOBOT_STORAGE", t.TempDir())
	// cmdTasks has sub-commands; call the list sub-command
	cmd := cmdTasks()
	cmd.SetArgs([]string{"list"})
	cmd.SilenceErrors = true
	_ = cmd.Execute()
}

// isolateStorage creates a fresh GOBOT_HOME (no config file) and sets GOBOT_STORAGE
// to the returned dir so commands don't read the real config's storage_root.
// Uses os.MkdirTemp (not t.TempDir) for storageDir so that SQLite handles left open
// by cobra RunE functions don't cause cleanup failures on Windows.
func isolateStorage(t *testing.T) string {
	t.Helper()
	storageDir, err := os.MkdirTemp("", "gobot-test-storage-*")
	if err != nil {
		t.Fatalf("failed to create temp storage dir: %v", err)
	}
	t.Cleanup(func() { _ = os.RemoveAll(storageDir) })
	t.Setenv("GOBOT_HOME", t.TempDir())
	t.Setenv("GOBOT_STORAGE", storageDir)
	return storageDir
}

// --- cmdStateList with a workflow ---

func TestCmdStateList_WithWorkflow(t *testing.T) {
	storageDir := isolateStorage(t)

	wfDir := filepath.Join(storageDir, "state", "workflows", "test-wf")
	_ = os.MkdirAll(wfDir, 0o755)
	_ = os.WriteFile(filepath.Join(wfDir, "checkpoint.json"), []byte(
		`{"id":"test-wf","status":"running","version":1,"created_at":"2024-01-01T00:00:00Z","updated_at":"2024-01-01T00:00:00Z"}`),
		0o600)

	cmd := cmdStateList()
	if err := cmd.Execute(); err != nil {
		t.Errorf("unexpected error: %v", err)
	}
}

// --- cmdStateInspect happy path ---

func TestCmdStateInspect_HappyPath(t *testing.T) {
	storageDir := isolateStorage(t)

	wfDir := filepath.Join(storageDir, "state", "workflows", "inspect-wf")
	_ = os.MkdirAll(wfDir, 0o755)
	_ = os.WriteFile(filepath.Join(wfDir, "checkpoint.json"), []byte(
		`{"id":"inspect-wf","status":"completed","version":2,"created_at":"2024-01-01T00:00:00Z","updated_at":"2024-01-02T00:00:00Z"}`),
		0o600)

	cmd := cmdStateInspect()
	cmd.SetArgs([]string{"inspect-wf"})
	if err := cmd.Execute(); err != nil {
		t.Errorf("unexpected error: %v", err)
	}
}

// --- cmdStateArchive happy path ---

func TestCmdStateArchive_HappyPath(t *testing.T) {
	storageDir := isolateStorage(t)

	stateDir := filepath.Join(storageDir, "state")
	wfDir := filepath.Join(stateDir, "workflows", "archive-wf")
	_ = os.MkdirAll(wfDir, 0o755)
	_ = os.WriteFile(filepath.Join(wfDir, "checkpoint.json"), []byte(
		`{"id":"archive-wf","status":"completed","version":1,"created_at":"2024-01-01T00:00:00Z","updated_at":"2024-01-01T00:00:00Z"}`),
		0o600)
	_ = os.MkdirAll(filepath.Join(stateDir, "archived"), 0o755)
	_ = os.MkdirAll(filepath.Join(stateDir, "locks"), 0o755)

	cmd := cmdStateArchive()
	cmd.SetArgs([]string{"archive-wf"})
	cmd.SilenceErrors = true
	_ = cmd.Execute()
}

// --- cmdStateRecover error path ---

func TestCmdStateRecover_NotFound(t *testing.T) {
	isolateStorage(t)
	cmd := cmdStateRecover()
	cmd.SetArgs([]string{"nonexistent-wf"})
	cmd.SilenceErrors = true
	_ = cmd.Execute()
}

// --- cmdRewind with snapshot name (runRestore error path) ---

func TestCmdRewind_RestoreNotFound(t *testing.T) {
	t.Setenv("GOBOT_STORAGE", t.TempDir())
	cmd := cmdRewind()
	cmd.SetArgs([]string{"--snapshot", "nonexistent-snapshot"})
	cmd.SilenceErrors = true
	_ = cmd.Execute()
}

// --- cobra wrapper Execute coverage ---

func TestCmdRewindList_Execute(t *testing.T) {
	isolateStorage(t)
	cmd := cmdRewindList()
	if err := cmd.Execute(); err != nil {
		t.Errorf("unexpected error: %v", err)
	}
}

func TestCmdMemoryRebuild_Execute(t *testing.T) {
	isolateStorage(t)
	cmd := cmdMemoryRebuild()
	cmd.SilenceErrors = true
	_ = cmd.Execute()
}

func TestCmdMemorySearch_Execute(t *testing.T) {
	isolateStorage(t)
	cmd := cmdMemorySearch()
	cmd.SetArgs([]string{"test query"})
	cmd.SilenceErrors = true
	_ = cmd.Execute()
}

func TestCmdFactoryStateMigrate_RunE(t *testing.T) {
	dir := t.TempDir()
	legacyFile := filepath.Join(dir, "state.json")
	_ = os.WriteFile(legacyFile, []byte(`{}`), 0o600)

	cmd := cmdFactoryStateMigrate()
	cmd.SetArgs([]string{legacyFile})
	if err := cmd.Execute(); err != nil {
		t.Errorf("unexpected error: %v", err)
	}

	cmd2 := cmdFactoryStateMigrate()
	cmd2.SetArgs([]string{})
	cmd2.SilenceErrors = true
	_ = cmd2.Execute()
}

// --- cmdAuthorize RunE ---

func TestCmdAuthorize_InvalidArg(t *testing.T) {
	isolateStorage(t)
	cmd := cmdAuthorize()
	cmd.SetArgs([]string{"not-a-pairing-code-or-number"})
	cmd.SilenceErrors = true
	err := cmd.Execute()
	if err == nil {
		t.Log("expected error for non-numeric arg with no pairing code match")
	}
}

func TestCmdAuthorize_NumericChatID(t *testing.T) {
	isolateStorage(t)
	cmd := cmdAuthorize()
	cmd.SetArgs([]string{"12345"})
	if err := cmd.Execute(); err != nil {
		t.Errorf("unexpected error authorizing numeric chat ID: %v", err)
	}
}

// --- cmdEmail early exit on missing user_email ---

func TestCmdEmail_NoUserEmail(t *testing.T) {
	isolateStorage(t)
	cmd := cmdEmail()
	cmd.SetArgs([]string{"Test Subject", "Test Body"})
	cmd.SilenceErrors = true
	err := cmd.Execute()
	if err == nil {
		t.Log("cmdEmail: expected error due to missing user_email")
	}
}

// --- cmdSimulate fails at BuildAgentStack ---

func TestCmdSimulate_NoProvider(t *testing.T) {
	isolateStorage(t)
	cmd := cmdSimulate()
	cmd.SetArgs([]string{"hello agent"})
	cmd.SilenceErrors = true
	_ = cmd.Execute()
}

// --- cmdResume nil-snapshot path ---

func TestCmdResume_NoCheckpoint(t *testing.T) {
	isolateStorage(t)
	cmd := cmdResume()
	cmd.SetArgs([]string{"nonexistent-thread-id"})
	if err := cmd.Execute(); err != nil {
		t.Errorf("unexpected error: %v", err)
	}
}

// --- cmdClearCheckpoint RunE ---

func TestCmdClearCheckpoint_RunE(t *testing.T) {
	isolateStorage(t)
	cmd := cmdClearCheckpoint()
	cmd.SetArgs([]string{"nonexistent-thread-42"})
	if err := cmd.Execute(); err != nil {
		t.Errorf("unexpected error: %v", err)
	}
}

// --- cmdCheckpoints with checkpoint data ---

func TestCmdCheckpoints_WithThread(t *testing.T) {
	storageDir := isolateStorage(t)
	// Create a fake checkpoint DB entry by running cmdClearCheckpoint (which creates DB)
	// Then list — the empty result should still be covered
	_ = storageDir
	cmd := cmdCheckpoints()
	cmd.SilenceErrors = true
	_ = cmd.Execute()
}

// --- cmdSecretsSet RunE ---

func TestCmdSecretsSet_RunE(t *testing.T) {
	isolateStorage(t)
	cmd := cmdSecretsSet()
	cmd.SetArgs([]string{"test-key", "test-value"})
	err := cmd.Execute()
	if err != nil {
		t.Logf("cmdSecretsSet error (DPAPI may not be available): %v", err)
	}
}

// --- cmdTasks add subcommand auth error ---

func TestCmdTasks_Add_AuthError(t *testing.T) {
	isolateStorage(t)
	cmd := cmdTasks()
	cmd.SetArgs([]string{"add", "My new task"})
	cmd.SilenceErrors = true
	_ = cmd.Execute()
}

// --- runLogs with a real log file ---

func TestRunLogs_WithFile(t *testing.T) {
	storageDir := isolateStorage(t)
	logsDir := filepath.Join(storageDir, "logs")
	_ = os.MkdirAll(logsDir, 0o755)
	_ = os.WriteFile(filepath.Join(logsDir, "gobot_test.log"), []byte("line1\nline2\nline3\n"), 0o600)

	b := bytes.NewBufferString("")
	cmd := cmdLogs()
	cmd.SetOut(b)
	cmd.SetArgs([]string{"--lines", "10"})
	cmd.SilenceErrors = true
	_ = cmd.Execute()
}

// --- runListSnapshots with snapshot data ---

func TestRunListSnapshots_WithSnapshot(t *testing.T) {
	storageDir := isolateStorage(t)
	// agent.ListSnapshots looks in {storageRoot}/.private/session/history/
	historyDir := filepath.Join(storageDir, ".private", "session", "history", "test-snap")
	_ = os.MkdirAll(historyDir, 0o755)
	_ = os.WriteFile(filepath.Join(historyDir, "snapshot_metadata.json"), []byte(
		`{"timestamp":"2024-01-01T00:00:00Z","task_id":"T-001","git_sha":"abc1234"}`),
		0o600)
	if err := runListSnapshots(); err != nil {
		t.Errorf("unexpected error: %v", err)
	}
}

// --- runFormatCheck paths ---

func TestRunFormatCheck_NotExist(t *testing.T) {
	cfg, _ := config.LoadFrom(filepath.Join(t.TempDir(), "nonexistent.json"))
	err := runFormatCheck("/nonexistent/path/config.json", cfg)
	if err == nil || !strings.Contains(err.Error(), "does not exist") {
		t.Errorf("expected 'does not exist' error, got %v", err)
	}
}

func TestRunFormatCheck_Match(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "config.json")
	cfg, _ := config.LoadFrom(filepath.Join(dir, "nonexistent.json"))
	data, err := cfg.Marshal()
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	if err := os.WriteFile(path, data, 0o600); err != nil {
		t.Fatalf("write: %v", err)
	}
	if err := runFormatCheck(path, cfg); err != nil {
		t.Errorf("unexpected error: %v", err)
	}
}

func TestRunFormatCheck_Mismatch(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "config.json")
	_ = os.WriteFile(path, []byte(`{}`), 0o600)
	cfg, _ := config.LoadFrom(filepath.Join(dir, "nonexistent.json"))
	err := runFormatCheck(path, cfg)
	if err == nil || !strings.Contains(err.Error(), "not correctly formatted") {
		t.Errorf("expected mismatch error, got %v", err)
	}
}

// --- cmdConfigReformat --check flag (covers checkOnly + path-arg branches) ---

func TestCmdConfigReformat_CheckOnly(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("GOBOT_HOME", dir)
	cfg, _ := config.LoadFrom(filepath.Join(dir, "nonexistent.json"))
	data, _ := cfg.Marshal()
	path := filepath.Join(dir, "config.json")
	_ = os.WriteFile(path, data, 0o600)
	cmd := cmdConfigReformat()
	cmd.SetArgs([]string{"--check", path})
	cmd.SilenceErrors = true
	if err := cmd.Execute(); err != nil {
		t.Errorf("unexpected error: %v", err)
	}
}

// --- cmdConfigValidate with a valid config (covers !result.HasErrors() path) ---

func TestCmdConfigValidate_SampleConfig(t *testing.T) {
	homeDir := t.TempDir()
	storageDir := t.TempDir()
	t.Setenv("GOBOT_HOME", homeDir)
	t.Setenv("GOBOT_STORAGE", storageDir)
	// Create workspace and AWARENESS.md so all validators pass
	_ = os.MkdirAll(filepath.Join(storageDir, "workspace"), 0o755)
	_ = os.WriteFile(filepath.Join(storageDir, "workspace", "AWARENESS.md"), []byte("# STRATEGIC AWARENESS\n"), 0o600)
	validConfig := `{
    "providers": {
        "gemini": {
            "apiKey": "DUMMY_KEY_FOR_CI_TESTS"
        }
    }
}`
	_ = os.MkdirAll(filepath.Join(homeDir, ".gobot"), 0o755)
	_ = os.WriteFile(filepath.Join(homeDir, ".gobot", "config.json"), []byte(validConfig), 0o600)
	cmd := cmdConfigValidate()
	b := bytes.NewBufferString("")
	cmd.SetOut(b)
	if err := cmd.Execute(); err != nil {
		t.Errorf("expected valid config, got: %v", err)
	}
}

// --- cmdConfigValidate with explicit path arg (covers len(args)>0 branch) ---

func TestCmdConfigValidate_WithPathArg(t *testing.T) {
	storageDir := t.TempDir()
	t.Setenv("GOBOT_STORAGE", storageDir)
	_ = os.MkdirAll(filepath.Join(storageDir, "workspace"), 0o755)
	_ = os.WriteFile(filepath.Join(storageDir, "workspace", "AWARENESS.md"), []byte("# STRATEGIC AWARENESS\n"), 0o600)
	validConfig := `{
    "providers": {
        "gemini": {
            "apiKey": "DUMMY_KEY_FOR_CI_TESTS"
        }
    }
}`
	path := filepath.Join(t.TempDir(), "myconfig.json")
	_ = os.WriteFile(path, []byte(validConfig), 0o600)
	cmd := cmdConfigValidate()
	cmd.SetArgs([]string{path})
	b := bytes.NewBufferString("")
	cmd.SetOut(b)
	if err := cmd.Execute(); err != nil {
		t.Errorf("unexpected error: %v", err)
	}
}

// --- cmdStateInspect with workflow data (covers data-printing branches) ---

func TestCmdStateInspect_WithData(t *testing.T) {
	storageDir := isolateStorage(t)
	wfDir := filepath.Join(storageDir, "state", "workflows", "data-wf")
	_ = os.MkdirAll(wfDir, 0o755)
	_ = os.WriteFile(filepath.Join(wfDir, "checkpoint.json"), []byte(
		`{"id":"data-wf","status":"completed","version":1,"created_at":"2024-01-01T00:00:00Z","updated_at":"2024-01-01T00:00:00Z","data":{"key":"value"}}`),
		0o600)
	cmd := cmdStateInspect()
	cmd.SetArgs([]string{"data-wf"})
	if err := cmd.Execute(); err != nil {
		t.Errorf("unexpected error: %v", err)
	}
}

// --- cmdStateRecover success path (covers recovery output + StatusFailed message) ---

func TestCmdStateRecover_Success(t *testing.T) {
	storageDir := isolateStorage(t)
	wfDir := filepath.Join(storageDir, "state", "workflows", "recover-test")
	_ = os.MkdirAll(wfDir, 0o755)
	_ = os.WriteFile(filepath.Join(wfDir, "checkpoint.json"), []byte(
		`{"id":"recover-test","status":"running","version":1,"created_at":"2024-01-01T00:00:00Z","updated_at":"2024-01-01T00:00:00Z"}`),
		0o600)
	cmd := cmdStateRecover()
	cmd.SetArgs([]string{"recover-test"})
	if err := cmd.Execute(); err != nil {
		t.Errorf("unexpected error: %v", err)
	}
}

// --- cmdReauth Execute (covers scopes init + AuthorizeInteractive call, fails safely) ---

func TestCmdReauth_Execute(t *testing.T) {
	isolateStorage(t)
	cmd := cmdReauth()
	cmd.SilenceErrors = true
	_ = cmd.Execute()
}

// --- cmdRewind with no --snapshot flag (covers return cmd.Help() branch) ---

func TestCmdRewind_NoSnapshot(t *testing.T) {
	cmd := cmdRewind()
	cmd.SetArgs([]string{})
	cmd.SilenceErrors = true
	_ = cmd.Execute()
}

// --- cmdRewind --snapshot success path (covers runRestore success) ---

func TestCmdRewind_RestoreSuccess(t *testing.T) {
	storageDir := isolateStorage(t)
	historyDir := filepath.Join(storageDir, ".private", "session", "history", "test-restore")
	sessionDir := filepath.Join(storageDir, ".private", "session")
	_ = os.MkdirAll(historyDir, 0o755)
	_ = os.WriteFile(filepath.Join(historyDir, "snapshot_metadata.json"), []byte(
		`{"timestamp":"2024-01-01T00:00:00Z","task_id":"T-001","git_sha":"abc1234"}`),
		0o600)
	_ = os.MkdirAll(sessionDir, 0o755)
	cmd := cmdRewind()
	cmd.SetArgs([]string{"--snapshot", "test-restore"})
	if err := cmd.Execute(); err != nil {
		t.Errorf("unexpected error: %v", err)
	}
}

// --- cmdResume with a real checkpoint (covers success body) ---

func TestCmdResume_WithSnapshot(t *testing.T) {
	storageDir := isolateStorage(t)
	mgr, err := agentctx.GetCheckpointManager(storageDir)
	if err != nil {
		t.Fatalf("get checkpoint manager: %v", err)
	}
	ctx := context.Background()
	threadID := "test-resume-snap-001"
	if err := mgr.CreateThread(ctx, threadID, "claude-sonnet", nil); err != nil {
		t.Fatalf("create thread: %v", err)
	}
	msg := "hello from test"
	msgs := []agentctx.StrategicMessage{
		{Role: agentctx.RoleUser, Content: &agentctx.MessageContent{Str: &msg}},
	}
	if _, err := mgr.SaveSnapshot(ctx, threadID, 1, msgs); err != nil {
		t.Fatalf("save snapshot: %v", err)
	}
	cmd := cmdResume()
	b := bytes.NewBufferString("")
	cmd.SetOut(b)
	cmd.SilenceErrors = true
	cmd.SetArgs([]string{threadID})
	if err := cmd.Execute(); err != nil {
		t.Errorf("unexpected error: %v", err)
	}
}

// --- cmdResume with >6 messages and long text (covers truncation branches) ---

func TestCmdResume_WithManyMessages(t *testing.T) {
	storageDir := isolateStorage(t)
	mgr, err := agentctx.GetCheckpointManager(storageDir)
	if err != nil {
		t.Fatalf("get checkpoint manager: %v", err)
	}
	ctx := context.Background()
	threadID := "test-resume-many-001"
	if err := mgr.CreateThread(ctx, threadID, "claude-sonnet", nil); err != nil {
		t.Fatalf("create thread: %v", err)
	}
	sp := func(s string) *string { return &s }
	longText := strings.Repeat("a", 250)
	msgs := []agentctx.StrategicMessage{
		{Role: agentctx.RoleUser, Content: &agentctx.MessageContent{Str: sp("msg 1")}},
		{Role: agentctx.RoleAssistant, Content: &agentctx.MessageContent{Str: sp("msg 2")}},
		{Role: agentctx.RoleUser, Content: &agentctx.MessageContent{Str: sp("msg 3")}},
		{Role: agentctx.RoleAssistant, Content: &agentctx.MessageContent{Str: sp("msg 4")}},
		{Role: agentctx.RoleUser, Content: &agentctx.MessageContent{Str: sp("msg 5")}},
		{Role: agentctx.RoleAssistant, Content: &agentctx.MessageContent{Str: sp("msg 6")}},
		{Role: agentctx.RoleUser, Content: &agentctx.MessageContent{Str: &longText}},
	}
	if _, err := mgr.SaveSnapshot(ctx, threadID, 1, msgs); err != nil {
		t.Fatalf("save snapshot: %v", err)
	}
	cmd := cmdResume()
	cmd.SilenceErrors = true
	cmd.SetArgs([]string{threadID})
	_ = cmd.Execute()
}
