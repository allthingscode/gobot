package reporter

import (
	_ "embed"
	"fmt"
	"html"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/allthingscode/gobot/internal/config"
)

//go:embed templates/default_email.css
var defaultCSS string

//go:embed templates/email.html
var defaultHTML string

//nolint:gochecknoglobals // Global template manager; thread-safe via sync.RWMutex
var (
	tmMu sync.RWMutex
	tm   *TemplateManager
)

// TemplateManager handles the loading and substitution of email templates.
type TemplateManager struct {
	css  string
	html string
}

// NewTemplateManager initializes a TemplateManager, loading from dir if provided.
func NewTemplateManager(dir string) *TemplateManager {
	mgr := &TemplateManager{
		css:  strings.TrimSpace(defaultCSS),
		html: strings.TrimSpace(defaultHTML),
	}

	if dir != "" {
		cssPath := filepath.Join(dir, "email.css")
		if b, err := os.ReadFile(cssPath); err == nil {
			mgr.css = strings.TrimSpace(string(b))
		}

		htmlPath := filepath.Join(dir, "email.html")
		if b, err := os.ReadFile(htmlPath); err == nil {
			mgr.html = strings.TrimSpace(string(b))
		}
	}

	return mgr
}

// NewTemplateManagerWithCSS initializes a TemplateManager, loading from dir if provided,
// and optionally overriding CSS with customCSSPath.
func NewTemplateManagerWithCSS(dir, customCSSPath string) *TemplateManager {
	mgr := &TemplateManager{
		css:  strings.TrimSpace(defaultCSS),
		html: strings.TrimSpace(defaultHTML),
	}

	if customCSSPath != "" {
		if b, err := os.ReadFile(customCSSPath); err == nil {
			mgr.css = strings.TrimSpace(string(b))
		}
	} else if dir != "" {
		cssPath := filepath.Join(dir, "email.css")
		if b, err := os.ReadFile(cssPath); err == nil {
			mgr.css = strings.TrimSpace(string(b))
		}
	}

	if dir != "" {
		htmlPath := filepath.Join(dir, "email.html")
		if b, err := os.ReadFile(htmlPath); err == nil {
			mgr.html = strings.TrimSpace(string(b))
		}
	}

	return mgr
}

// Wrap inspects the body and wraps it with CSS and HTML if necessary.
func (m *TemplateManager) Wrap(body string) string {
	if !looksLikeHTML(body) {
		return body
	}

	body = CompactSources(body)
	lowerBody := strings.ToLower(body)

	style := "<style>" + m.css + "</style>"

	if !strings.Contains(lowerBody, "<html") {
		out := m.html
		out = strings.Replace(out, "{{.Style}}", m.css, 1)
		out = strings.Replace(out, "{{.Body}}", body, 1)
		return out
	}

	headIdx := strings.Index(lowerBody, "</head>")
	if headIdx != -1 {
		return body[:headIdx] + style + body[headIdx:]
	}

	return style + body
}

// FallbackNotify writes a notification entry to {storageRoot}/workspace/NOTIFICATIONS.md
// when email delivery is unavailable. Creates the file if it does not exist.
// Returns a human-readable status string.
func FallbackNotify(storageRoot, subject, body, recipient, reason string) string {
	notifFile := filepath.Join(storageRoot, "workspace", "NOTIFICATIONS.md")
	dir := filepath.Dir(notifFile)

	if err := os.MkdirAll(dir, 0o755); err != nil {
		return fmt.Sprintf("CRITICAL: Fallback notification failed. Original: %s. Disk error: %v", reason, err)
	}

	cleanReason := reason
	lowerReason := strings.ToLower(reason)
	if strings.Contains(lowerReason, "invalid_grant") || strings.Contains(lowerReason, "token expired") {
		cleanReason = "AUTH EXPIRED. Run: gobot reauth"
	}

	timestamp := time.Now().Format("2006-01-02 15:04:05")
	entry := fmt.Sprintf("\n---\n### [%s] %s\n**To:** %s\n**Fallback Reason:** %s\n\n%s\n",
		timestamp, subject, recipient, cleanReason, body)

	_, err := os.Stat(notifFile)
	isNew := os.IsNotExist(err)

	f, err := os.OpenFile(notifFile, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o644)
	if err != nil {
		return fmt.Sprintf("CRITICAL: Fallback notification failed. Original: %s. Disk error: %v", reason, err)
	}
	defer func() { _ = f.Close() }()

	if isNew {
		if _, err := f.WriteString("# Strategic Notifications (Fallback)\n"); err != nil {
			return fmt.Sprintf("CRITICAL: Fallback notification failed. Original: %s. Disk error: %v", reason, err)
		}
	}

	if _, err := f.WriteString(entry); err != nil {
		return fmt.Sprintf("CRITICAL: Fallback notification failed. Original: %s. Disk error: %v", reason, err)
	}

	return fmt.Sprintf("Gmail unavailable (%s). Report saved to: %s", cleanReason, notifFile)
}

// WrapHTML detects whether body is HTML and, if so, injects a CSS stylesheet and
// wraps the content in a container div. Plain text bodies are returned unchanged.
// HTML is detected if the lowercased body contains any common HTML tag.
func WrapHTML(body string) string {
	tmMu.RLock()
	localTM := tm
	tmMu.RUnlock()

	if localTM == nil {
		tmMu.Lock()
		if tm == nil {
			dir := ""
			cssPath := ""
			if cfg, err := config.Load(); err == nil && cfg != nil {
				dir = cfg.TemplatesPath()
				if cfg.Strategic.CustomCSSPath != "" {
					cssPath = cfg.Strategic.CustomCSSPath
				}
			}
			tm = NewTemplateManagerWithCSS(dir, cssPath)
		}
		localTM = tm
		tmMu.Unlock()
	}

	return localTM.Wrap(body)
}

// htmlTagRe matches any HTML tag for stripping purposes.
var htmlTagRe = regexp.MustCompile("<[^>]+>")

// sourceRe matches [Sources: URL] citations produced by the briefing agent.
var sourceRe = regexp.MustCompile(`\[Sources:\s*([^\]]+)\]`)

// CompactSources replaces verbose inline [Sources: URL] citations with numbered
// references and appends a compact source appendix at the end of the message.
func CompactSources(body string) string {
	matches := sourceRe.FindAllStringSubmatchIndex(body, -1)
	if len(matches) == 0 {
		return body
	}

	isHTML := looksLikeHTML(body)
	urlToIndex, indexToURL := make(map[string]int), make([]string, 0, 8)
	rewritten := rewriteInlineSources(body, matches, urlToIndex, &indexToURL)

	if len(indexToURL) == 0 {
		return rewritten
	}

	return rewritten + buildSourceAppendix(indexToURL, isHTML)
}

func rewriteInlineSources(body string, matches [][]int, urlToIndex map[string]int, indexToURL *[]string) string {
	var b strings.Builder
	last := 0

	for _, m := range matches {
		if len(m) < 4 {
			continue
		}
		start, end, cStart, cEnd := m[0], m[1], m[2], m[3]
		b.WriteString(body[last:start])

		indices := sourceIndices(body[cStart:cEnd], urlToIndex, indexToURL)
		if len(indices) == 0 {
			b.WriteString(body[start:end])
		} else {
			b.WriteString("[Sources: ")
			b.WriteString(strings.Join(indices, ", "))
			b.WriteString("]")
		}
		last = end
	}

	b.WriteString(body[last:])
	return b.String()
}

func sourceIndices(rawSources string, urlToIndex map[string]int, indexToURL *[]string) []string {
	parts := strings.Split(rawSources, ",")
	indices := make([]string, 0, len(parts))
	for _, part := range parts {
		u := strings.TrimSpace(part)
		if u == "" {
			continue
		}
		idx, ok := urlToIndex[u]
		if !ok {
			*indexToURL = append(*indexToURL, u)
			idx = len(*indexToURL)
			urlToIndex[u] = idx
		}
		indices = append(indices, strconv.Itoa(idx))
	}
	return indices
}

func buildSourceAppendix(indexToURL []string, isHTML bool) string {
	var appendix strings.Builder
	if isHTML {
		appendix.WriteString("<h3>Sources</h3><ol>")
		for _, u := range indexToURL {
			appendix.WriteString(`<li><a href="`)
			appendix.WriteString(html.EscapeString(u))
			appendix.WriteString(`">`)
			appendix.WriteString(html.EscapeString(u))
			appendix.WriteString("</a></li>")
		}
		appendix.WriteString("</ol>")
		return appendix.String()
	}
	appendix.WriteString("\n\nSources\n")
	for i, u := range indexToURL {
		appendix.WriteString(strconv.Itoa(i + 1))
		appendix.WriteString(". ")
		appendix.WriteString(u)
		appendix.WriteString("\n")
	}
	return strings.TrimRight(appendix.String(), "\n")
}

func looksLikeHTML(body string) bool {
	lowerBody := strings.ToLower(body)
	htmlTags := []string{"<html", "<body>", "<h1", "<h2", "<h3", "<p>", "<div", "<ul>", "<ol>", "<li>", "<strong>", "<em>", "<span"}
	for _, tag := range htmlTags {
		if strings.Contains(lowerBody, tag) {
			return true
		}
	}
	return false
}

// StripHTML removes HTML tags from s to produce a plain-text fallback.
// Block-level closing tags are replaced with newlines for readability.
// Used to generate the text/plain part of multipart emails.
func StripHTML(s string) string {
	for _, tag := range []string{"</p>", "</div>", "</h1>", "</h2>", "</h3>", "<br>", "<br/>", "<br />"} {
		s = strings.ReplaceAll(s, tag, "\n")
	}
	s = htmlTagRe.ReplaceAllString(s, "")
	// Collapse runs of blank lines down to one.
	for strings.Contains(s, "\n\n\n") {
		s = strings.ReplaceAll(s, "\n\n\n", "\n\n")
	}
	return strings.TrimSpace(s)
}
