package main

import (
	"context"
	"strings"
	"testing"
)

func TestCompleteTaskTool_Name(t *testing.T) {
	tool := newCompleteTaskTool("/tmp/secrets")
	if tool.Name() != completeTaskToolName {
		t.Errorf("Name() = %q, want %q", tool.Name(), completeTaskToolName)
	}
}

func TestCompleteTaskTool_MissingTaskID(t *testing.T) {
	tool := newCompleteTaskTool("/tmp/secrets")
	_, err := tool.Execute(context.Background(), "session:1", map[string]any{"task_id": ""})
	if err == nil {
		t.Fatal("expected error for missing task_id, got nil")
	}
	if !strings.Contains(err.Error(), "task_id is required") {
		t.Errorf("error %q should contain 'task_id is required'", err.Error())
	}
}

func TestUpdateTaskTool_Name(t *testing.T) {
	tool := newUpdateTaskTool("/tmp/secrets")
	if tool.Name() != updateTaskToolName {
		t.Errorf("Name() = %q, want %q", tool.Name(), updateTaskToolName)
	}
}

func TestUpdateTaskTool_MissingTaskID(t *testing.T) {
	tool := newUpdateTaskTool("/tmp/secrets")
	_, err := tool.Execute(context.Background(), "session:1", map[string]any{
		"task_id": "",
		"title":   "something",
	})
	if err == nil {
		t.Fatal("expected error for missing task_id, got nil")
	}
	if !strings.Contains(err.Error(), "task_id is required") {
		t.Errorf("error %q should contain 'task_id is required'", err.Error())
	}
}

func TestCompleteTaskTool_Declaration(t *testing.T) {
	tool := newCompleteTaskTool("/tmp/secrets")
	decl := tool.Declaration()

	props, _ := decl.Parameters["properties"].(map[string]any)
	if _, ok := props["task_id"]; !ok {
		t.Error("Declaration missing task_id parameter")
	}
	found := false
	reqs, _ := decl.Parameters["required"].([]string)
	for _, r := range reqs {
		if r == "task_id" {
			found = true
		}
	}
	if !found {
		t.Error("task_id must be in Required")
	}
}

func TestUpdateTaskTool_Declaration(t *testing.T) {
	tool := newUpdateTaskTool("/tmp/secrets")
	decl := tool.Declaration()

	props, _ := decl.Parameters["properties"].(map[string]any)
	for _, p := range []string{"task_id", "title", "notes", "due", "tasklist_id"} {
		if _, ok := props[p]; !ok {
			t.Errorf("Declaration missing parameter %q", p)
		}
	}
	reqs, _ := decl.Parameters["required"].([]string)
	if len(reqs) != 1 || reqs[0] != "task_id" {
		t.Errorf("Required should be [task_id], got %v", reqs)
	}
}
