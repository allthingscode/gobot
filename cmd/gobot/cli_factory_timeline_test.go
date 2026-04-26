package main

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestFactoryTimelineCommand_Text(t *testing.T) { //nolint:paralleltest // changes process cwd
	root := t.TempDir()
	writeTimelineTestFile(t, filepath.Join(root, ".private", "session", "C-185", "pipeline.log.jsonl"), `{"event":"handoff","timestamp":"2026-04-26T10:10:00Z","source_specialist":"architect","target_specialist":"reviewer","reason":"ready"}`)
	writeTimelineTestFile(t, filepath.Join(root, ".private", "session", "C-185", "architect", "task.md"), "### CHECKPOINT done\n")

	restore := chdirForTest(t, root)
	defer restore()

	out := bytes.NewBufferString("")
	cmd := cmdFactory()
	cmd.SetOut(out)
	cmd.SetArgs([]string{"timeline", "--task", "C-185"})
	if err := cmd.Execute(); err != nil {
		t.Fatalf("command failed: %v", err)
	}

	got := out.String()
	if !strings.Contains(got, "Task Timeline: C-185") {
		t.Fatalf("missing header in output: %s", got)
	}
	if !strings.Contains(got, "architect -> reviewer") {
		t.Fatalf("missing handoff edge in output: %s", got)
	}
	if !strings.Contains(got, "checkpoint") {
		t.Fatalf("missing checkpoint event in output: %s", got)
	}
}

func TestFactoryTimelineCommand_JSON(t *testing.T) { //nolint:paralleltest // changes process cwd
	root := t.TempDir()
	writeTimelineTestFile(t, filepath.Join(root, ".private", "session", "C-185", "pipeline.log.jsonl"), `{"event":"session_start","timestamp":"2026-04-26T10:00:00Z","specialist":"architect"}`)

	restore := chdirForTest(t, root)
	defer restore()

	out := bytes.NewBufferString("")
	cmd := cmdFactory()
	cmd.SetOut(out)
	cmd.SetArgs([]string{"timeline", "--task", "C-185", "--json"})
	if err := cmd.Execute(); err != nil {
		t.Fatalf("command failed: %v", err)
	}

	got := out.String()
	if !strings.Contains(got, `"task_id": "C-185"`) {
		t.Fatalf("expected task_id in json output: %s", got)
	}
	if !strings.Contains(got, `"event_type": "session_start"`) {
		t.Fatalf("expected event_type in json output: %s", got)
	}
}

func TestFactoryTimelineCommand_MissingTaskFlag(t *testing.T) { //nolint:paralleltest // cobra global command state
	cmd := cmdFactory()
	cmd.SetArgs([]string{"timeline"})
	err := cmd.Execute()
	if err == nil {
		t.Fatal("expected error when --task is missing")
	}
	if !strings.Contains(err.Error(), "required flag(s) \"task\" not set") {
		t.Fatalf("unexpected error: %v", err)
	}
}

func chdirForTest(t *testing.T, dir string) func() {
	t.Helper()
	wd, err := os.Getwd()
	if err != nil {
		t.Fatalf("getwd: %v", err)
	}
	if err := os.Chdir(dir); err != nil {
		t.Fatalf("chdir: %v", err)
	}
	return func() {
		if err := os.Chdir(wd); err != nil {
			t.Fatalf("restore chdir: %v", err)
		}
	}
}

func writeTimelineTestFile(t *testing.T, path, content string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatalf("mkdir parent: %v", err)
	}
	if err := os.WriteFile(path, []byte(content), 0o600); err != nil {
		t.Fatalf("write file: %v", err)
	}
}
