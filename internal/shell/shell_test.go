package shell_test

import (
	"testing"

	"github.com/allthingscode/gobot/internal/shell"
)

// ── StripCLIXML ──────────────────────────────────────────────────────────────

func TestStripCLIXML(t *testing.T) {
	tests := []struct {
		name  string
		input string
		want  string
	}{
		{
			name:  "passthrough_no_clixml",
			input: "normal output",
			want:  "normal output",
		},
		{
			name:  "extracts_error_tag",
			input: "#< CLIXML\n<Objs><S S=\"Error\">Something went wrong_x000D__x000A_</S></Objs>",
			want:  "POWERSHELL ERROR: Something went wrong",
		},
		{
			name:  "unescapes_xml_entities",
			input: "#< CLIXML\n<Objs><S S=\"Error\">&lt;path&gt; &amp; file</S></Objs>",
			want:  "POWERSHELL ERROR: <path> & file",
		},
		{
			name:  "fallback_strips_tags",
			input: "#< CLIXML\n<Objs><S>no error attribute here</S></Objs>",
			want:  "POWERSHELL ERROR (Raw): no error attribute here",
		},
		{
			name:  "clixml_header_only",
			input: "#< CLIXML",
			want:  "POWERSHELL ERROR (Raw): ",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := shell.StripCLIXML(tt.input)
			if got != tt.want {
				t.Errorf("StripCLIXML(%q)\n  got  %q\n  want %q", tt.input, got, tt.want)
			}
		})
	}
}

// ── RedirectCDrive ────────────────────────────────────────────────────────────

func TestRedirectCDrive(t *testing.T) {
	workspaceRoot := `D:\Gobot_Storage\workspace`
	projectRoot := `gobot`

	tests := []struct {
		name  string
		input string
		want  string
	}{
		{
			name:  "passthrough_no_c_drive",
			input: `Get-Content D:\Gobot_Storage\workspace\file.txt`,
			want:  `Get-Content D:\Gobot_Storage\workspace\file.txt`,
		},
		{
			name:  "unquoted_c_drive_redirected",
			input: `New-Item C:\canary.txt`,
			want:  `New-Item D:\Gobot_Storage\workspace\canary.txt`,
		},
		{
			name:  "double_quoted_c_drive_redirected",
			input: `New-Item "C:\path with spaces\file.txt"`,
			want:  `New-Item "D:\Gobot_Storage\workspace\file.txt"`,
		},
		{
			name:  "single_quoted_c_drive_redirected",
			input: `Set-Content 'C:\temp\out.txt' -Value hello`,
			want:  `Set-Content 'D:\Gobot_Storage\workspace\out.txt' -Value hello`,
		},
		{
			name:  "gobot_project_root_untouched",
			input: `python C:\Users\HayesChiefOfStaff\Documents\gobot\run.py`,
			want:  `python C:\Users\HayesChiefOfStaff\Documents\gobot\run.py`,
		},
		{
			name:  "gobot_project_root_trailing_untouched",
			input: `python C:\Users\HayesChiefOfStaff\Documents\gobot`,
			want:  `python C:\Users\HayesChiefOfStaff\Documents\gobot`,
		},
		{
			name:  "case_insensitive_match",
			input: `echo c:\canary.txt`,
			want:  `echo D:\Gobot_Storage\workspace\canary.txt`,
		},
		{
			name:  "multiple_c_paths_in_one_command",
			input: `Copy-Item C:\src\a.txt C:\src\b.txt`,
			want:  `Copy-Item D:\Gobot_Storage\workspace\a.txt D:\Gobot_Storage\workspace\b.txt`,
		},
		{
			name:  "mixed_separators_in_inner_path",
			input: `New-Item C:\temp/slash\file.txt`,
			want:  `New-Item D:\Gobot_Storage\workspace\file.txt`,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := shell.RedirectCDrive(tt.input, workspaceRoot, projectRoot)
			if got != tt.want {
				t.Errorf("RedirectCDrive(%q)\n  got  %q\n  want %q", tt.input, got, tt.want)
			}
		})
	}
}
