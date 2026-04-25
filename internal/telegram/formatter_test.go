//nolint:testpackage // requires unexported formatter internals for testing
package telegram

import "testing"

func TestToHTML(t *testing.T) {
	t.Parallel()
	tests := []struct{ name, input, want string }{
		{"empty", "", ""},
		{"passthrough", "hello world", "hello world"},
		{"bold*", "**bold**", "<b>bold</b>"},
		{"bold_", "__bold__", "<b>bold</b>"},
		{"italic*", "*italic*", "<i>italic</i>"},
		{"italic_", "_italic_", "<i>italic</i>"},
		{"code", "`code`", "<code>code</code>"},
		{"code escape", "`a<b>`", "<code>a&lt;b&gt;</code>"},
		{"fenced", "```\nfoo bar\n```", "<pre><code>foo bar\n</code></pre>"},
		{"fenced+lang", "```go\nfunc f() {}\n```", "<pre><code>func f() {}\n</code></pre>"},
		{"fenced script", "```\n<script>\n```", "<pre><code>&lt;script&gt;\n</code></pre>"},
		{"link", "[Google](https://google.com)", `<a href="https://google.com">Google</a>`},
		{"blockquote", "> hello", "<blockquote>hello</blockquote>"},
		{"bq bold", "> **bold**", "<blockquote><b>bold</b></blockquote>"},
		{"escape", "a < b & c > d", "a &lt; b &amp; c &gt; d"},
		{"complex", "**bold** and _italic_ with `code` and [link](https://x.com)", `<b>bold</b> and <i>italic</i> with <code>code</code> and <a href="https://x.com">link</a>`},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			got := ToHTML(tt.input)
			if got != tt.want {
				t.Errorf("got %q, want %q", got, tt.want)
			}
		})
	}
}
