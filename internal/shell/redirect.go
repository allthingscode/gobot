package shell

import (
	"path/filepath"
	"regexp"
	"strings"
)

// workspaceRoot is the mandated destination for all redirected C: drive paths (BUG-228/240).
const workspaceRoot = `D:\Nanobot_Storage\workspace`

var (
	reDoubleQuotedC = regexp.MustCompile(`(?i)"C:\\[^"]*"`)
	reSingleQuotedC = regexp.MustCompile(`(?i)'C:\\[^']*'`)
	reUnquotedC     = regexp.MustCompile(`(?i)C:\\[^;"'\s]+`)
)

// RedirectCDrive rewrites C:\ paths in a PowerShell command to the mandated
// D:\Nanobot_Storage\workspace (BUG-228/240). Three passes handle double-quoted,
// single-quoted, and unquoted paths. Paths under the nanobot project root
// ("Documents\nanobot") are left untouched.
func RedirectCDrive(command string) string {
	command = reDoubleQuotedC.ReplaceAllStringFunc(command, func(m string) string {
		return redirectPath(m, `"`)
	})
	command = reSingleQuotedC.ReplaceAllStringFunc(command, func(m string) string {
		return redirectPath(m, `'`)
	})
	command = reUnquotedC.ReplaceAllStringFunc(command, func(m string) string {
		return redirectPath(m, "")
	})
	return command
}

// redirectPath rewrites a single matched C:\ path. quote is the surrounding
// delimiter ("", `"`, or `'`). Returns path unchanged if it belongs to the
// nanobot project root.
func redirectPath(path, quote string) string {
	inner := path
	if quote != "" {
		inner = path[1 : len(path)-1]
	}
	if strings.Contains(strings.ToLower(inner), `documents\nanobot`) {
		return path
	}
	name := filepath.Base(inner)
	redirected := workspaceRoot + `\` + name
	if quote != "" {
		return quote + redirected + quote
	}
	return redirected
}
