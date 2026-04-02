package shell

import (
	"path/filepath"
	"regexp"
	"strings"
)

var (
	reDoubleQuotedC = regexp.MustCompile(`(?i)"C:\\[^"]*"`)
	reSingleQuotedC = regexp.MustCompile(`(?i)'C:\\[^']*'`)
	reUnquotedC     = regexp.MustCompile(`(?i)C:\\[^;"'\s]+`)
)

// RedirectCDrive rewrites C:\ paths in a PowerShell command to the mandated
// workspaceRoot. Three passes handle double-quoted, single-quoted, and unquoted
// paths. Paths under the projectRoot (e.g. "Documents\gobot") are left untouched.
func RedirectCDrive(command, workspaceRoot, projectRoot string) string {
	command = reDoubleQuotedC.ReplaceAllStringFunc(command, func(m string) string {
		return redirectPath(m, `"`, workspaceRoot, projectRoot)
	})
	command = reSingleQuotedC.ReplaceAllStringFunc(command, func(m string) string {
		return redirectPath(m, `'`, workspaceRoot, projectRoot)
	})
	command = reUnquotedC.ReplaceAllStringFunc(command, func(m string) string {
		return redirectPath(m, "", workspaceRoot, projectRoot)
	})
	return command
}

// redirectPath rewrites a single matched C:\ path. quote is the surrounding
// delimiter ("", `"`, or `'`). Returns path unchanged if it belongs to the
// projectRoot.
func redirectPath(path, quote, workspaceRoot, projectRoot string) string {
	inner := path
	if quote != "" {
		inner = path[1 : len(path)-1]
	}
	if projectRoot != "" && strings.Contains(strings.ToLower(inner), strings.ToLower(projectRoot)) {
		return path
	}
	name := filepath.Base(inner)
	redirected := filepath.Join(workspaceRoot, name)
	if quote != "" {
		return quote + redirected + quote
	}
	return redirected
}
