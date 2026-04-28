package shell

//nolint:gochecknoglobals // immutable lookup table; no exported var to avoid API churn
var unixCommands = map[string]bool{
	"ls": true, "cat": true, "grep": true, "rm": true, "cp": true,
	"mv": true, "pwd": true, "touch": true, "find": true,
	"head": true, "tail": true, "chmod": true, "which": true,
}

// RemapUnixCommand rewrites Unix-only commands to run through PowerShell,
// which provides aliases (ls, cat, grep→Select-String, etc.) on Windows.
// Non-Unix commands are returned unchanged.
func RemapUnixCommand(cmd string, args []string) (outCmd string, outArgs []string) {
	if !unixCommands[cmd] {
		return cmd, args
	}
	psArgs := make([]string, 0, len(args)+3)
	psArgs = append(psArgs, "-NoProfile", "-Command", cmd)
	psArgs = append(psArgs, args...)
	return "powershell", psArgs
}
