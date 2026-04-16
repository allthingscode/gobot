package shell_test

import (
	"testing"

	"github.com/allthingscode/gobot/internal/shell"
)

func TestStripCLIXML(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name     string
		input    string
		expected string
	}{
		{
			name:     "No CLIXML header",
			input:    "normal output",
			expected: "normal output",
		},
		{
			name:     "Error block extracted",
			input:    "#< CLIXML\r\n<Objs Version=\"1.1.0.1\" xmlns=\"http://schemas.microsoft.com/powershell/2004/04\"><S S=\"Error\">some error_x000D__x000A_</S></Objs>",
			expected: "POWERSHELL ERROR: some error",
		},
		{
			name:     "Error block with HTML entities",
			input:    "#< CLIXML\n<S S=\"Error\">file &lt;path&gt; &amp; name</S>",
			expected: "POWERSHELL ERROR: file <path> & name",
		},
		{
			name:     "Multiple lines in error block",
			input:    "#< CLIXML\n<S S=\"Error\">line 1_x000D__x000A_line 2</S>",
			expected: "POWERSHELL ERROR: line 1\nline 2",
		},
		{
			name:     "Fallback: CLIXML header but no Error block",
			input:    "#< CLIXML\n<Objs><S S=\"Info\">some info</S></Objs>",
			expected: "POWERSHELL ERROR (Raw): some info",
		},
		{
			name:     "Fallback strips XML tags",
			input:    "#< CLIXML\n<Objs><S>text without error attribute</S><BARE>more text</BARE></Objs>",
			expected: "POWERSHELL ERROR (Raw): text without error attributemore text",
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			got := shell.StripCLIXML(tc.input)
			if got != tc.expected {
				t.Errorf("StripCLIXML() = %q, expected %q", got, tc.expected)
			}
		})
	}
}
