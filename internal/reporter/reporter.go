package reporter

import (
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"time"
)

const emailCSS = `body{font-family:'Segoe UI',Tahoma,Geneva,Verdana,sans-serif;line-height:1.6;color:#f0f6fc;background-color:#0a0b10;margin:0;padding:20px;font-size:18px}.container{max-width:800px;margin:0 auto;background:#161b22;padding:40px;border:1px solid #30363d;border-radius:4px;color:#f0f6fc !important}h1,h2,h3{color:#58a6ff;border-bottom:2px solid #30363d;padding-bottom:10px}a{color:#58a6ff;text-decoration:none}code{background:#0d1117;padding:2px 5px;color:#79c0ff}.vitality{font-family:'Georgia',serif;font-style:italic;color:#a5d6ff !important;font-size:1.25em;line-height:1.5;margin:20px 0}.audit{font-family:'Cascadia Code','Consolas',monospace;font-size:12px;color:#8b949e;background-color:#0d1117;border:1px solid #30363d;padding:15px;border-radius:4px;margin-top:30px}`

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
	defer f.Close()

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
	lowerBody := strings.ToLower(body)
	htmlTags := []string{"<html", "<body>", "<h1", "<h2", "<h3", "<p>", "<div", "<ul>", "<ol>", "<li>", "<strong>", "<em>", "<span"}
	isHTML := false
	for _, tag := range htmlTags {
		if strings.Contains(lowerBody, tag) {
			isHTML = true
			break
		}
	}
	if !isHTML {
		return body
	}

	style := "<style>" + emailCSS + "</style>"

	if !strings.Contains(lowerBody, "<html") {
		return "<!DOCTYPE html><html><head>" + style + "</head><body><div class='container'>" + body + "</div></body></html>"
	}

	headIdx := strings.Index(lowerBody, "</head>")
	if headIdx != -1 {
		return body[:headIdx] + style + body[headIdx:]
	}

	return style + body
}

// htmlTagRe matches any HTML tag for stripping purposes.
var htmlTagRe = regexp.MustCompile(`<[^>]+>`)

// StripHTML removes HTML tags from s to produce a plain-text fallback.
// Block-level closing tags are replaced with newlines for readability.
// Used to generate the text/plain part of multipart emails.
func StripHTML(html string) string {
	s := html
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
