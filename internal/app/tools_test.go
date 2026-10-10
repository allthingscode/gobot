package app_test

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/allthingscode/gobot/internal/app"
	"github.com/allthingscode/gobot/internal/config"
)

const (
	readTextFileName    = "read_text_file"
	dummyProjectContent = "project"
)

func TestReadTextFileTool_Name(t *testing.T) {
	t.Parallel()
	tool := &app.ReadTextFileTool{}
	if tool.Name() != readTextFileName {
		t.Errorf("Name() = %q, want 'read_text_file'", tool.Name())
	}
}

func TestReadTextFileTool_Declaration(t *testing.T) {
	t.Parallel()
	tool := &app.ReadTextFileTool{}
	decl := tool.Declaration()
	if decl.Name != readTextFileName {
		t.Errorf("Declaration.Name = %q, want 'read_text_file'", decl.Name)
	}
}

func TestReadTextFileTool_Execute_Success(t *testing.T) {
	t.Parallel()
	tmpDir := t.TempDir()
	content := "Hello, Go!"
	// Create file in the expected workspace subdirectory
	workspaceDir := filepath.Join(tmpDir, "workspace")
	if err := os.MkdirAll(workspaceDir, 0o755); err != nil {
		t.Fatal(err)
	}
	filePath := filepath.Join(workspaceDir, "test.txt")
	if err := os.WriteFile(filePath, []byte(content), 0o600); err != nil {
		t.Fatal(err)
	}

	cfg := &config.Config{}
	cfg.Runtime.StorageRoot = tmpDir
	tool := app.NewReadTextFileTool(cfg)
	got, err := tool.Execute(context.Background(), "sess", "user", map[string]any{
		"file_path": "test.txt",
	})
	if err != nil {
		t.Fatalf("Execute failed: %v", err)
	}
	if got != content {
		t.Errorf("Execute got %q, want %q", got, content)
	}
}

func TestReadTextFileTool_Execute_SandboxEscaping(t *testing.T) {
	t.Parallel()
	tmpDir := t.TempDir()
	cfg := &config.Config{}
	cfg.Runtime.StorageRoot = tmpDir
	tool := app.NewReadTextFileTool(cfg)

	// Attempt to read something outside the sandbox
	_, err := tool.Execute(context.Background(), "sess", "user", map[string]any{
		"file_path": "../outside.txt",
	})
	if err == nil {
		t.Fatal("expected error for path outside sandbox, got nil")
	}
	if !strings.Contains(err.Error(), "is outside allowed roots") {
		t.Errorf("expected sandbox error, got: %v", err)
	}
}

func TestReadTextFileTool_Execute_ProjectRootFallback(t *testing.T) {
	t.Parallel()
	tmpDir := t.TempDir()

	// Create a workspace root and a project root
	workspaceDir := filepath.Join(tmpDir, "workspace")
	projectDir := filepath.Join(tmpDir, dummyProjectContent)
	if err := os.MkdirAll(workspaceDir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(projectDir, 0o755); err != nil {
		t.Fatal(err)
	}

	// Create file ONLY in project root
	content := "Project Content"
	filePath := filepath.Join(projectDir, "project_file.txt")
	if err := os.WriteFile(filePath, []byte(content), 0o600); err != nil {
		t.Fatal(err)
	}

	cfg := &config.Config{}
	cfg.Runtime.StorageRoot = tmpDir // WorkspacePath(userID) will use this + /workspace
	cfg.SetProjectRoot(projectDir)

	tool := app.NewReadTextFileTool(cfg)
	got, err := tool.Execute(context.Background(), "sess", "user", map[string]any{
		"file_path": "project_file.txt",
	})
	if err != nil {
		t.Fatalf("Execute failed: %v", err)
	}
	if got != content {
		t.Errorf("Execute got %q, want %q", got, content)
	}
}

func TestRegisterTools_App(t *testing.T) {
	t.Parallel()
	cfg := &config.Config{}
	prov := &app.MockProvider{}
	tools := app.RegisterTools(cfg, prov, "model", nil, nil, nil, nil, nil, nil, nil)
	if len(tools) == 0 {
		t.Error("RegisterTools returned zero tools")
	}
}

// Dummy trees keep every link test independent of real host files.
func containmentFixture(t *testing.T) (tool *app.ReadTextFileTool, cfg *config.Config, workspace, project, outside string) {
	t.Helper()
	base := t.TempDir()
	workspace = filepath.Join(base, "workspace")
	project = filepath.Join(base, dummyProjectContent)
	outside = filepath.Join(base, "outside")
	for _, root := range []string{workspace, project, outside} {
		if err := os.Mkdir(root, 0o755); err != nil {
			t.Fatal(err)
		}
		writeDummy(t, filepath.Join(root, "marker"), filepath.Base(root))
	}
	cfg = &config.Config{}
	cfg.Runtime.StorageRoot = base
	cfg.SetProjectRoot(project)
	return app.NewReadTextFileTool(cfg), cfg, workspace, project, outside
}

func writeDummy(t *testing.T, path, content string) {
	t.Helper()
	if err := os.WriteFile(path, []byte(content), 0o600); err != nil {
		t.Fatal(err)
	}
}

func readDummy(tool app.Tool, path string) (string, error) {
	return tool.Execute(context.Background(), "dummy", "user", map[string]any{"file_path": path})
}

func dummySymlink(t *testing.T, target, link string) {
	t.Helper()
	if err := os.Symlink(target, link); err != nil {
		t.Skipf("symlink fixture unavailable (Windows may require privilege): %v", err)
	}
}

func TestReadTextFileContainmentNormal(t *testing.T) {
	t.Parallel()
	tool, _, workspace, project, outside := containmentFixture(t)
	writeDummy(t, filepath.Join(workspace, "..notes"), "dots")
	writeDummy(t, filepath.Join(project, "project-only"), dummyProjectContent)
	for _, tc := range []struct {
		name, path, want string
		fail             bool
	}{
		{"relative workspace", "marker", "workspace", false},
		{"absolute workspace", filepath.Join(workspace, "marker"), "workspace", false},
		{"relative fallback", "project-only", dummyProjectContent, false},
		{"absolute fallback", filepath.Join(project, "marker"), dummyProjectContent, false},
		{"dotdot name", "..notes", "dots", false},
		{"missing", "missing", "", true},
		{"traversal", filepath.Join("..", "outside", "marker"), "", true},
		{"outside absolute", filepath.Join(outside, "marker"), "", true},
		{"sibling prefix", workspace + "-sibling/marker", "", true},
		{"directory terminal", ".", "", true},
		{"empty argument", "", "", true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			got, err := readDummy(tool, tc.path)
			if (err != nil) != tc.fail || got != tc.want {
				t.Fatalf("read = %q, %v; want %q, fail=%v", got, err, tc.want, tc.fail)
			}
		})
	}
}

func TestReadTextFileContainmentLinks(t *testing.T) {
	t.Parallel()
	for _, tc := range []struct {
		name, root, target, want string
		fail                     bool
	}{
		{"workspace in-root", "workspace", "marker", "workspace", false},
		{"project in-root", dummyProjectContent, "marker", dummyProjectContent, false},
		{"workspace escape blocks fallback", "workspace", "../outside/marker", "", true},
		{"project escape", dummyProjectContent, "../outside/marker", "", true},
		{"absolute in-root", "workspace", "absolute", "", true},
		{"absolute outside", "workspace", "outside", "", true},
		{"loop blocks fallback", "workspace", "link", "", true},
		{"dangling safe fallback", "workspace", "missing", dummyProjectContent, false},
		{"read failure blocks fallback", "workspace", ".", "", true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			tool, _, workspace, project, outside := containmentFixture(t)
			root := workspace
			if tc.root == dummyProjectContent {
				root = project
			} else {
				writeDummy(t, filepath.Join(project, "link"), dummyProjectContent)
			}
			target := filepath.FromSlash(tc.target)
			switch target {
			case "absolute":
				target = filepath.Join(root, "marker")
			case "outside":
				target = filepath.Join(outside, "marker")
			}
			dummySymlink(t, target, filepath.Join(root, "link"))
			got, err := readDummy(tool, "link")
			if (err != nil) != tc.fail || got != tc.want {
				t.Fatalf("read = %q, %v; want %q, fail=%v", got, err, tc.want, tc.fail)
			}
		})
	}
}

func TestWireSubToolsFileContainment(t *testing.T) {
	t.Parallel()
	_, cfg, workspace, _, _ := containmentFixture(t)
	dummySymlink(t, filepath.FromSlash("../outside/marker"), filepath.Join(workspace, "link"))
	got, err := readDummy(spawnedReadTool(t, cfg), "link")
	if err == nil || got != "" {
		t.Fatalf("spawned read = %q, %v", got, err)
	}
}

func spawnedReadTool(t *testing.T, cfg *config.Config) app.Tool {
	t.Helper()
	tools := app.RegisterTools(cfg, &app.MockProvider{}, "dummy", nil, nil, nil, nil, nil, nil, nil)
	for _, tool := range tools {
		spawn, ok := tool.(*app.SpawnTool)
		if !ok {
			continue
		}
		for _, sub := range spawn.SubTools {
			if sub.Name() == readTextFileName {
				return sub
			}
		}
	}
	t.Fatal("read tool absent from spawned subset")
	return nil
}

func TestReadTextFileContainmentLinkReplacement(t *testing.T) {
	t.Parallel()
	tool, _, workspace, _, outside := containmentFixture(t)
	link := filepath.Join(workspace, "changing")
	dummySymlink(t, "marker", link)
	// Bounded stress evidence supplements the Root API guarantee; observing no
	// leakage alone does not prove confinement. Only isolated dummy links change.
	done := make(chan struct{})
	errorsCh := make(chan error, 1)
	go replaceDummyLinks(link, outside, done, errorsCh)
	leaked := false
	for range 300 {
		got, _ := readDummy(tool, "changing")
		if got != "" && got != "workspace" {
			leaked = true
		}
	}
	<-done
	select {
	case err := <-errorsCh:
		t.Fatalf("link replacement fixture: %v", err)
	default:
	}
	if leaked {
		t.Fatal("link replacement returned outside contents")
	}
}

func TestReadTextFileContainmentTrustedLinkedRoot(t *testing.T) {
	t.Parallel()
	tool, cfg, _, project, _ := containmentFixture(t)
	linked := filepath.Join(filepath.Dir(project), "trusted-root")
	dummySymlink(t, project, linked)
	cfg.SetProjectRoot(linked)
	got, err := readDummy(tool, filepath.Join(linked, "marker"))
	if err != nil || got != dummyProjectContent {
		t.Fatalf("trusted linked root = %q, %v", got, err)
	}
}

func replaceDummyLinks(link, outside string, done chan<- struct{}, errorsCh chan<- error) {
	defer close(done)
	for i := range 200 {
		if err := os.Remove(link); err != nil {
			errorsCh <- err
			return
		}
		target := "marker"
		if i%2 == 0 {
			target = filepath.Join(outside, "marker")
		}
		if err := os.Symlink(target, link); err != nil {
			errorsCh <- err
			return
		}
	}
}
