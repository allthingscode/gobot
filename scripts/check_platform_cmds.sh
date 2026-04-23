#!/bin/sh
# scripts/check_platform_cmds.sh
# Detects unguarded Windows-specific shell commands in tests.
#
# Patterns to match:
# - "cmd"
# - cmd.exe
# - cmd /c or cmd /C
# - powershell or powershell.exe
# - .bat", .cmd", .exe"

set -e

# Temporary file to track failures inside subshells (while loops)
FAILED_MARKER=$(mktemp)
rm -f "$FAILED_MARKER"

# Patterns that indicate Windows-specific commands
PATTERNS='("cmd"|cmd\.exe|cmd /c|cmd /C|powershell|powershell\.exe|\.bat"|\.cmd"|\.exe")'

# Find all test files, excluding vendor/ and isolated worktrees
files=$(find . -name "*_test.go" -not -path "./vendor/*" -not -path "./.agent-workspaces/*")

for file in $files; do
    # 1. Skip files that are explicitly tagged for windows only
    if head -n 20 "$file" | grep -qE "(//go:build windows|// \+build windows)"; then
        continue
    fi

    # 2. Search for patterns and get line numbers.
    # We filter out known false positives:
    # - filepath.Join(..., "cmd") which refers to the cmd/ directory
    # - http/https URLs containing powershell
    # - "cmd": as a map key
    # - "command": "cmd" as a map entry (often mocked)
    # - cmdExecutor = "cmd" or similar constant definitions
    grep -nE "$PATTERNS" "$file" | \
        grep -v "filepath.Join" | \
        grep -v "http" | \
        grep -vE '"cmd":[[:space:]]*' | \
        grep -vE '"command":[[:space:]]*"cmd"' | \
        grep -vE '[[:space:]]*=[[:space:]]*"cmd"' | \
        while IFS=: read -r line_num content; do
            
            # Look back 15 lines for a runtime.GOOS guard
            start_line=$(($line_num - 15))
            if [ "$start_line" -lt 1 ]; then
                start_line=1
            fi
            
            # Check if the preceding 15 lines contain runtime.GOOS
            if ! sed -n "${start_line},${line_num}p" "$file" | grep -q "runtime.GOOS"; then
                echo "ERROR: Unguarded platform-specific command in test file."
                echo "  File: ${file#./}:${line_num}"
                # Trim leading whitespace from the matched line
                trimmed_content=$(echo "$content" | sed 's/^[[:space:]]*//')
                echo "  Match: $trimmed_content"
                echo ""
                echo "  This command only works on Windows. Wrap it in a runtime.GOOS guard:"
                echo ""
                echo "    if runtime.GOOS == \"windows\" {"
                echo "        cmd, args = \"cmd\", []string{\"/c\", \"echo hello\"}"
                echo "    } else {"
                echo "        cmd, args = \"sh\", []string{\"-c\", \"echo hello\"}"
                echo "    }"
                echo ""
                touch "$FAILED_MARKER"
            fi
        done
done

if [ -f "$FAILED_MARKER" ]; then
    rm -f "$FAILED_MARKER"
    exit 1
fi

exit 0
