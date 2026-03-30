package telegram

import "testing"

func TestToHTML(t *testing.T) {
	tests := []struct {
		name  string
		input string
		want  string
	}{
		{
			name:  "empty string",
			input: "",
			want:  "",
		},
		{
			name:  "plain text passthrough",
			input: "hello world",
			want:  "hello world",
		},
		{
			name:  "bold asterisks",
			input: "**bold**",
			want:  "<b>bold</b>",
		},
		{
			name:  "bold underscores",
			input: "__bold__",
			want:  "<b>bold</b>",
		},
		{
			name:  "italic asterisk",
			input: "*italic*",
			want:  "<i>italic</i>",
		},
		{
			name:  "italic underscore",
			input: "_italic_",
			want:  "<i>italic</i>",
		},
		{
			name:  "inline code",
			input: "`code`",
			want:  "<code>code</code>",
		},
		{
			name:  "inline code escapes HTML",
			input: "`a<b>`",
			want:  "<code>a&lt;b&gt;</code>",
		},
		{
			name:  "fenced code block",
			input: "```\nfoo bar\n```",
			want:  "<pre><code>foo bar\n</code></pre>",
		},
		{
			name:  "fenced code with language tag",
			input: "```go\nfunc f() {}\n```",
			want:  "<pre><code>func f() {}\n</code></pre>",
		},
		{
			name:  "fenced code escapes HTML",
			input: "```\n<script>\n```",
			want:  "<pre><code>&lt;script&gt;\n</code></pre>",
		},
		{
			name:  "hyperlink",
			input: "[Google](https://google.com)",
			want:  `<a href="https://google.com">Google</a>`,
		},
		{
			name:  "blockquote",
			input: "> hello",
			want:  "<blockquote>hello</blockquote>",
		},
		{
			name:  "bold inside blockquote",
			input: "> **bold**",
			want:  "<blockquote><b>bold</b></blockquote>",
		},
		{
			name:  "HTML chars in prose are escaped",
			input: "a < b & c > d",
			want:  "a &lt; b &amp; c &gt; d",
		},
		{
			name:  "complex: bold italic code link",
			input: "**bold** and _italic_ with `code` and [link](https://x.com)",
			want:  `<b>bold</b> and <i>italic</i> with <code>code</code> and <a href="https://x.com">link</a>`,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := ToHTML(tt.input)
			if got != tt.want {
				t.Errorf("ToHTML(%q)\n got  %q\n want %q", tt.input, got, tt.want)
			}
		})
	}
}
