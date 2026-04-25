package shell_test

import (
	"path/filepath"
	"testing"

	"github.com/allthingscode/gobot/internal/shell"
)

func TestRedirectCDrive(t *testing.T) {
	t.Parallel()
	// We use neutral mock paths for testing the logic.
	workspaceRoot := filepath.FromSlash("/mock/workspace")
	projectRoot := filepath.FromSlash("/mock/project")

	tests := []struct {
		name  string
		input string
		want  string
	}{
		{
			name:  "passthrough_already_in_workspace",
			input: `Get-Content ` + filepath.Join(workspaceRoot, "file.txt"),
			want:  `Get-Content ` + filepath.Join(workspaceRoot, "file.txt"),
		},
		{
			name:  "unquoted_drive_redirected",
			input: `New-Item C:\canary.txt`,
			want:  `New-Item ` + filepath.Join(workspaceRoot, "canary.txt"),
		},
		{
			name:  "double_quoted_drive_redirected",
			input: `New-Item "C:\path with spaces\file.txt"`,
			want:  `New-Item "` + filepath.Join(workspaceRoot, "path with spaces", "file.txt") + `"`,
		},
		{
			name:  "single_quoted_drive_redirected",
			input: `Set-Content 'C:\temp\out.txt' -Value hello`,
			want:  `Set-Content '` + filepath.Join(workspaceRoot, "temp", "out.txt") + `' -Value hello`,
		},
		{
			name:  "project_root_untouched",
			input: `node ` + filepath.Join(projectRoot, "run.js"),
			want:  `node ` + filepath.Join(projectRoot, "run.js"),
		},
		{
			name:  "case_insensitive_match",
			input: `echo c:\canary.txt`,
			want:  `echo ` + filepath.Join(workspaceRoot, "canary.txt"),
		},
		{
			name:  "multiple_paths_in_one_command",
			input: `Copy-Item C:\src\a.txt C:\src\b.txt`,
			want:  `Copy-Item ` + filepath.Join(workspaceRoot, "src", "a.txt") + ` ` + filepath.Join(workspaceRoot, "src", "b.txt"),
		},
		{
			name:  "mixed_separators_in_inner_path",
			input: `New-Item C:\temp/slash\file.txt`,
			want:  `New-Item ` + filepath.Join(workspaceRoot, "temp", "slash", "file.txt"),
		},
		{
			name:  "forward_slash_drive_redirected",
			input: `ls C:/temp/file.txt`,
			want:  `ls ` + filepath.Join(workspaceRoot, "temp", "file.txt"),
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			got := shell.RedirectCDrive(tt.input, workspaceRoot, projectRoot)
			if got != tt.want {
				t.Errorf("RedirectCDrive(%q)\n  got  %q\n  want %q", tt.input, got, tt.want)
			}
		})
	}
}
