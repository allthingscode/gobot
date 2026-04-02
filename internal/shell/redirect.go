package shell

import (
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
// paths. Paths under the projectRoot (e.g. "gobot") are left untouched.
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

	// B-028: If projectRoot is provided, check if the path contains it as a directory component.
	// We use a case-insensitive check for common project names.
	if projectRoot != "" {
		normInner := strings.ToLower(inner)
		normRoot := strings.ToLower(projectRoot)
		// Check for \root\ or \root (at end)
		if strings.Contains(normInner, "\\"+normRoot+"\\") || strings.HasSuffix(normInner, "\\"+normRoot) {
			return path
		}
	}

	// B-027: Use custom base extractor that handles backslashes on any OS.
	name := winBase(inner)
	
	// Ensure we use backslashes for the redirected path since it's for a Windows sandbox.
	redirected := strings.TrimRight(workspaceRoot, "\\/") + "\\" + name

	if quote != "" {
		return quote + redirected + quote
	}
	return redirected
}

// winBase returns the last component of a path, handling both \ and /
// regardless of the host OS.
func winBase(path string) string {
	i := strings.LastIndexAny(path, "\\/")
	if i == -1 {
		return path
	}
	return path[i+1:]
}
