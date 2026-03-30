package telegram

import (
	"fmt"
	"html"
	"regexp"
	"strings"
)

var (
	reFenced  = regexp.MustCompile("```[a-zA-Z]*\\n?([\\s\\S]*?)```")
	reInline  = regexp.MustCompile("`([^`\n]+)`")
	reBoldAst = regexp.MustCompile(`\*\*(.+?)\*\*`)
	reBoldUnd = regexp.MustCompile(`__(.+?)__`)
	reItalAst = regexp.MustCompile(`\*([^*\n]+)\*`)
	reItalUnd = regexp.MustCompile(`_([^_\n]+)_`)
	reLink    = regexp.MustCompile(`\[([^\]]+)\]\(([^)]+)\)`)
	reSlot    = regexp.MustCompile("\x00(\\d+)\x00")
)

// ToHTML converts a Markdown subset to Telegram-compatible HTML.
// Supported: bold (**text** / __text__), italic (*text* / _text_),
// inline code (`code`), fenced code blocks (```...```),
// hyperlinks ([text](url)), and blockquotes (> text).
func ToHTML(md string) string {
	slots := make([]string, 0, 8)

	store := func(h string) string {
		i := len(slots)
		slots = append(slots, h)
		return fmt.Sprintf("\x00%d\x00", i)
	}

	// Stage 1: extract fenced code blocks; HTML-escape their content.
	out := reFenced.ReplaceAllStringFunc(md, func(m string) string {
		sub := reFenced.FindStringSubmatch(m)
		return store("<pre><code>" + html.EscapeString(sub[1]) + "</code></pre>")
	})

	// Stage 2: extract inline code spans; HTML-escape their content.
	out = reInline.ReplaceAllStringFunc(out, func(m string) string {
		sub := reInline.FindStringSubmatch(m)
		return store("<code>" + html.EscapeString(sub[1]) + "</code>")
	})

	// Stage 3: HTML-escape non-slot text (protects < > & in prose).
	segs := reSlot.Split(out, -1)
	refs := reSlot.FindAllString(out, -1)
	var b strings.Builder
	for i, seg := range segs {
		b.WriteString(html.EscapeString(seg))
		if i < len(refs) {
			b.WriteString(refs[i])
		}
	}
	out = b.String()

	// Stage 4: inline formatting — bold before italic to handle ** vs *.
	out = reBoldAst.ReplaceAllString(out, "<b>$1</b>")
	out = reBoldUnd.ReplaceAllString(out, "<b>$1</b>")
	out = reItalAst.ReplaceAllString(out, "<i>$1</i>")
	out = reItalUnd.ReplaceAllString(out, "<i>$1</i>")
	out = reLink.ReplaceAllString(out, `<a href="$2">$1</a>`)

	// Stage 5: blockquotes — note ">" was escaped to "&gt;" in stage 3.
	lines := strings.Split(out, "\n")
	for i, line := range lines {
		if strings.HasPrefix(line, "&gt; ") {
			lines[i] = "<blockquote>" + line[5:] + "</blockquote>"
		} else if line == "&gt;" {
			lines[i] = "<blockquote></blockquote>"
		}
	}
	out = strings.Join(lines, "\n")

	// Stage 6: restore stored HTML fragments.
	out = reSlot.ReplaceAllStringFunc(out, func(m string) string {
		var i int
		fmt.Sscanf(m, "\x00%d\x00", &i)
		if i < len(slots) {
			return slots[i]
		}
		return m
	})

	return out
}
