package shell

import (
	"path/filepath"
	"regexp"
	"strings"
)

var (
	// reDoubleQuotedC matches patterns like double-quoted absolute paths.
	// We use a pattern that matches a volume name followed by a colon and backslash.
	reDoubleQuotedPath = regexp.MustCompile(`(?i)"[A-Z]:\\[^"]*"`)
	// reSingleQuotedC matches patterns like single-quoted absolute paths.
	reSingleQuotedPath = regexp.MustCompile(`(?i)'[A-Z]:\\[^']*'`)
	// reUnquotedC matches patterns like unquoted absolute paths (standalone).
	reUnquotedPath = regexp.MustCompile(`(?i)[A-Z]:\\[^;"'\s]+`)
)

// RedirectCDrive rewrites absolute Windows system drive paths in a PowerShell command 
// to the mandated workspace root. This ensures that agents attempting to use 
// system temp paths are redirected to the durable storage automatically.
func RedirectCDrive(command, workspaceRoot, projectRoot string) string {
	// Skip redirection if the command contains the workspace root or project root already.
	// This prevents infinite recursion or double-pathing if the workspace is on the same drive.
	if (workspaceRoot != "" && strings.Contains(strings.ToLower(command), strings.ToLower(workspaceRoot))) ||
		(projectRoot != "" && strings.Contains(strings.ToLower(command), strings.ToLower(projectRoot))) {
		return command
	}

	res := reDoubleQuotedPath.ReplaceAllStringFunc(command, func(match string) string {
		return redirectPath(match, workspaceRoot, "\"")
	})
	res = reSingleQuotedPath.ReplaceAllStringFunc(res, func(match string) string {
		return redirectPath(match, workspaceRoot, "'")
	})
	res = reUnquotedPath.ReplaceAllStringFunc(res, func(match string) string {
		return redirectPath(match, workspaceRoot, "")
	})

	return res
}

// redirectPath rewrites a single matched absolute path. quote is the surrounding
// quote character (if any).
func redirectPath(match, workspaceRoot, quote string) string {
	// Strip quotes
	path := match
	if quote != "" {
		path = strings.Trim(match, quote)
	}

	vol := filepath.VolumeName(path)
	if vol == "" {
		return match // should not happen with our regex
	}

	// Extract the part after the volume name (e.g. system drive)
	inner := path[len(vol):]

	// Build new path using filepath.Join for OS-specific separators.
	// We trim leading separators from inner to ensure Join works correctly.
	newPath := filepath.Join(workspaceRoot, strings.TrimLeft(inner, "\\/"))

	// Restore quotes if they were present
	return quote + newPath + quote
}
