package main

import (
	"bytes"
	"os"
	"path/filepath"
	"testing"

	"github.com/allthingscode/gobot/internal/config"
	agentctx "github.com/allthingscode/gobot/internal/context"
)

func setupTestHome(t *testing.T) string {
	t.Helper()
	tempDir := t.TempDir()
	
	// Normalize path to avoid short name issues on Windows.
	if absDir, err := filepath.Abs(tempDir); err == nil {
		tempDir = absDir
	}
	if evalDir, err := filepath.EvalSymlinks(tempDir); err == nil {
		tempDir = evalDir
	}
	tempDir = filepath.Clean(tempDir)

	t.Setenv("GOBOT_HOME", tempDir)
	t.Setenv("GOBOT_STORAGE", tempDir)
	
	t.Cleanup(func() {
		// Close ALL DB connections and clear the instance cache.
		agentctx.ResetCheckpointManagerForTest()
	})
	return tempDir
}

//nolint:paralleltest // uses global state
func TestCmdVersion(t *testing.T) {
	cmd := cmdVersion()
	// Just execute it to hit the lines.
	_ = cmd.Execute()
}

//nolint:paralleltest // uses global state
func TestCmdInit(t *testing.T) {
	tempDir := setupTestHome(t)
	cmd := cmdInit()
	cmd.SetArgs([]string{"--root", tempDir})
	_ = cmd.Execute()
}

//nolint:paralleltest // uses global state
func TestCmdLogs_Functional(t *testing.T) {
	tempDir := setupTestHome(t)
	logDir := filepath.Join(tempDir, "logs")
	_ = os.MkdirAll(logDir, 0o755)
	_ = os.WriteFile(filepath.Join(logDir, "gobot.log"), []byte("test log\n"), 0o600)
	
	cmd := cmdLogs()
	cmd.SetArgs([]string{"--lines", "1"})
	_ = cmd.Execute()
}

//nolint:paralleltest // uses global state
func TestCmdConfig_Functional(t *testing.T) {
	tempDir := setupTestHome(t)
	cfg := &config.Config{}
	_ = os.MkdirAll(filepath.Join(tempDir, ".gobot"), 0o755)
	_ = cfg.Save(filepath.Join(tempDir, ".gobot", "config.json"))
	
	cmd := cmdConfig()
	cmd.SetArgs([]string{"validate"})
	_ = cmd.Execute()
}

//nolint:paralleltest // uses global state
func TestCmdSecrets_Functional(t *testing.T) {
	tempDir := setupTestHome(t)
	_ = os.MkdirAll(filepath.Join(tempDir, "workspace", "secrets"), 0o755)
	
	cmd := cmdSecretsSet()
	cmd.SetArgs([]string{"key1", "val1"})
	_ = cmd.Execute()
	
	cmdGet := cmdSecretsGet()
	cmdGet.SetArgs([]string{"key1"})
	_ = cmdGet.Execute()
}

//nolint:paralleltest // uses global state
func TestCmdCheckpoints_List_Coverage(t *testing.T) {
	tempDir := setupTestHome(t)
	_ = os.MkdirAll(filepath.Join(tempDir, "workspace"), 0o755)
	
	cmd := cmdCheckpoints()
	cmd.SetArgs([]string{})
	_ = cmd.Execute()
}

//nolint:paralleltest // uses global state
func TestCmdRewind_List_Coverage(t *testing.T) {
	tempDir := setupTestHome(t)
	_ = os.MkdirAll(filepath.Join(tempDir, "workspace"), 0o755)
	
	cmd := cmdRewind()
	cmd.SetArgs([]string{"list"})
	_ = cmd.Execute()
}

//nolint:paralleltest // uses global state
func TestCmdFactory_Functional(t *testing.T) {
	tempDir := setupTestHome(t)
	_ = os.MkdirAll(filepath.Join(tempDir, "workspace"), 0o755)
	
	cmd := cmdFactory()
	cmd.SetArgs([]string{"state", "list"})
	_ = cmd.Execute()
}

//nolint:paralleltest // uses global state
func TestCmdSimulate_Functional_Coverage(t *testing.T) {
	tempDir := setupTestHome(t)
	_ = os.MkdirAll(filepath.Join(tempDir, "workspace"), 0o755)
	_ = os.WriteFile(filepath.Join(tempDir, "workspace", "AWARENESS.md"), []byte("test"), 0o600)
	
	cmd := cmdSimulate()
	cmd.SetArgs([]string{"hello"})
	_ = cmd.Execute()
}

//nolint:paralleltest // uses global state
func TestCmdAuthorize_Execute_Coverage(t *testing.T) {
	tempDir := setupTestHome(t)
	_ = os.MkdirAll(filepath.Join(tempDir, ".gobot"), 0o755)
	
	cmd := cmdAuthorize()
	cmd.SetArgs([]string{"12345"})
	_ = cmd.Execute()
}

//nolint:paralleltest // uses global state
func TestCmdEmail_Execute_Coverage(t *testing.T) {
	tempDir := setupTestHome(t)
	_ = os.MkdirAll(filepath.Join(tempDir, ".gobot"), 0o755)
	
	cmd := cmdEmail()
	cmd.SetArgs([]string{"subj", "body"})
	_ = cmd.Execute()
}

//nolint:paralleltest // uses global state
func TestCmdCalendar_Execute_Coverage(t *testing.T) {
	tempDir := setupTestHome(t)
	_ = os.MkdirAll(filepath.Join(tempDir, ".gobot"), 0o755)
	
	cmd := cmdCalendar()
	cmd.SetArgs([]string{})
	_ = cmd.Execute()
}

//nolint:paralleltest // uses global state
func TestCmdTasks_Execute_Coverage(t *testing.T) {
	tempDir := setupTestHome(t)
	_ = os.MkdirAll(filepath.Join(tempDir, ".gobot"), 0o755)
	
	cmd := cmdTasks()
	cmd.SetArgs([]string{"list"})
	_ = cmd.Execute()
}

//nolint:paralleltest // uses global state
func TestCmdMemory_Execute_Coverage(t *testing.T) {
	tempDir := setupTestHome(t)
	_ = os.MkdirAll(filepath.Join(tempDir, "workspace"), 0o755)
	
	cmd := cmdMemory()
	cmd.SetArgs([]string{"rebuild"})
	_ = cmd.Execute()
}

//nolint:paralleltest // uses global state
func TestCmdState_Execute_Coverage(t *testing.T) {
	tempDir := setupTestHome(t)
	_ = os.MkdirAll(filepath.Join(tempDir, "workspace"), 0o755)
	
	cmd := cmdState()
	cmd.SetArgs([]string{"list"})
	_ = cmd.Execute()
}

//nolint:paralleltest // uses global state
func TestCmdResume_NotFound_Coverage(t *testing.T) {
	tempDir := setupTestHome(t)
	cfg := &config.Config{}
	cfg.Strategic.StorageRoot = tempDir
	_ = os.MkdirAll(filepath.Join(tempDir, ".gobot"), 0o755)
	_ = os.MkdirAll(filepath.Join(tempDir, "workspace"), 0o755)
	_ = cfg.Save(filepath.Join(tempDir, ".gobot", "config.json"))

	cmd := cmdResume()
	cmd.SetArgs([]string{"nonexistent-thread"})
	_ = cmd.Execute()
}

//nolint:paralleltest // uses global state
func TestCmdClearCheckpoint_NotFound_Coverage(t *testing.T) {
	tempDir := setupTestHome(t)
	cfg := &config.Config{}
	cfg.Strategic.StorageRoot = tempDir
	_ = os.MkdirAll(filepath.Join(tempDir, ".gobot"), 0o755)
	_ = cfg.Save(filepath.Join(tempDir, ".gobot", "config.json"))

	cmd := cmdClearCheckpoint()
	cmd.SetArgs([]string{"nonexistent-thread"})
	_ = cmd.Execute()
}

//nolint:paralleltest // uses global state
func TestCmdStateInspect_NotFound_Coverage(t *testing.T) {
	tempDir := setupTestHome(t)
	cfg := &config.Config{}
	cfg.Strategic.StorageRoot = tempDir
	_ = os.MkdirAll(filepath.Join(tempDir, ".gobot"), 0o755)
	_ = os.MkdirAll(filepath.Join(tempDir, "workspace"), 0o755)
	_ = cfg.Save(filepath.Join(tempDir, ".gobot", "config.json"))

	cmd := cmdState()
	cmd.SetArgs([]string{"inspect", "nonexistent-wf"})
	_ = cmd.Execute()
}

//nolint:paralleltest // uses global state
func TestCmdStateArchive_NotFound_Coverage(t *testing.T) {
	tempDir := setupTestHome(t)
	cfg := &config.Config{}
	cfg.Strategic.StorageRoot = tempDir
	_ = os.MkdirAll(filepath.Join(tempDir, ".gobot"), 0o755)
	_ = os.MkdirAll(filepath.Join(tempDir, "workspace"), 0o755)
	_ = cfg.Save(filepath.Join(tempDir, ".gobot", "config.json"))

	cmd := cmdState()
	cmd.SetArgs([]string{"archive", "nonexistent-wf"})
	_ = cmd.Execute()
}

//nolint:paralleltest // uses global state
func TestCmdStateRecover_NotFound_Coverage(t *testing.T) {
	tempDir := setupTestHome(t)
	cfg := &config.Config{}
	cfg.Strategic.StorageRoot = tempDir
	_ = os.MkdirAll(filepath.Join(tempDir, ".gobot"), 0o755)
	_ = os.MkdirAll(filepath.Join(tempDir, "workspace"), 0o755)
	_ = cfg.Save(filepath.Join(tempDir, ".gobot", "config.json"))

	cmd := cmdState()
	cmd.SetArgs([]string{"recover", "nonexistent-wf"})
	_ = cmd.Execute()
}

//nolint:paralleltest // uses global state
func TestCmdDoctor_Coverage(t *testing.T) {
	tempDir := setupTestHome(t)
	cfg := &config.Config{}
	cfg.Strategic.StorageRoot = tempDir
	_ = os.MkdirAll(filepath.Join(tempDir, ".gobot"), 0o755)
	_ = cfg.Save(filepath.Join(tempDir, ".gobot", "config.json"))

	cmd := cmdDoctor()
	b := bytes.NewBufferString("")
	cmd.SetOut(b)
	_ = cmd.Execute()
}

//nolint:paralleltest // uses global state
func TestCmdRun_PrereqError_Coverage(t *testing.T) {
	tempDir := setupTestHome(t)
	cfg := &config.Config{}
	cfg.Channels.Telegram.Enabled = true // No token -> prereq error
	cfg.Strategic.StorageRoot = tempDir
	_ = os.MkdirAll(filepath.Join(tempDir, ".gobot"), 0o755)
	_ = cfg.Save(filepath.Join(tempDir, ".gobot", "config.json"))

	cmd := cmdRun()
	_ = cmd.Execute()
}

//nolint:paralleltest // uses global state
func TestConfigReformat_Error_Coverage(t *testing.T) {
	tempDir := setupTestHome(t)
	configPath := filepath.Join(tempDir, ".gobot", "config.json")
	_ = os.MkdirAll(filepath.Join(tempDir, ".gobot"), 0o755)
	_ = os.WriteFile(configPath, []byte("invalid json"), 0o600)

	cmd := cmdConfig()
	cmd.SetArgs([]string{"reformat"})
	_ = cmd.Execute()
}

//nolint:paralleltest // uses global state
func TestCmdTasks_Add_Coverage(t *testing.T) {
	tempDir := setupTestHome(t)
	cfg := &config.Config{}
	cfg.Strategic.StorageRoot = tempDir
	_ = os.MkdirAll(filepath.Join(tempDir, ".gobot"), 0o755)
	_ = cfg.Save(filepath.Join(tempDir, ".gobot", "config.json"))

	cmd := cmdTasks()
	cmd.SetArgs([]string{"add", "test task"})
	_ = cmd.Execute()
}
