package shell

import (
	"regexp"
	"strings"
)

var (
	reErrorTag = regexp.MustCompile(`(?s)<S S="Error">(.*?)</S>`)
	reXMLTags  = regexp.MustCompile(`<[^>]+>`)
)

// StripCLIXML removes PowerShell CLIXML markers from text, extracting the plain
// error message where possible (BUG-247). Returns the input unchanged if no CLIXML
// header is present.
//
// Two-tier strategy:
//  1. Extract the first <S S="Error"> block and unescape its content.
//  2. Fallback: strip the header and all XML tags, prefix "POWERSHELL ERROR (Raw):".
func StripCLIXML(text string) string {
	if !strings.Contains(text, "#< CLIXML") {
		return text
	}

	if m := reErrorTag.FindStringSubmatch(text); m != nil {
		msg := m[1]
		msg = strings.ReplaceAll(msg, "_x000D__x000A_", "\n")
		msg = strings.ReplaceAll(msg, "&lt;", "<")
		msg = strings.ReplaceAll(msg, "&gt;", ">")
		msg = strings.ReplaceAll(msg, "&amp;", "&")
		return "POWERSHELL ERROR: " + strings.TrimSpace(msg)
	}

	// Fallback: strip header and all XML tags.
	clean := strings.ReplaceAll(text, "#< CLIXML", "")
	clean = reXMLTags.ReplaceAllString(clean, "")
	return "POWERSHELL ERROR (Raw): " + strings.TrimSpace(clean)
}
