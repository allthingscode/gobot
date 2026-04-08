//go:build ignore

// Command doc_lint checks that the gobot codebase and documentation stay in
// sync.  It is designed to run in CI (< 30 s) and produces actionable,
// human-readable output.
//
// Checks performed:
//  1. Exported standalone functions in internal/ and cmd/ must have a doc
//     comment.  Methods are excluded because they often implement interfaces
//     and rarely need separate docs.
//  2. Non-archived markdown files under .private/backlog/ may reference file
//     paths; every referenced path that looks like a project file must exist.
//  3. Every .md file in .private/backlog/features/ and .private/backlog/bugs/
//     must be mentioned (by filename) in BACKLOG.md.
//  4. Backlog item YAML frontmatter must contain a valid status field.
//  5. Specialist protocol enforcement (handoff schema, stale locks, state JSON).
package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"go/ast"
	"go/parser"
	"go/token"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"time"
)

func main() {
	root, err := os.Getwd()
	if err != nil {
		fmt.Fprintf(os.Stderr, "cannot determine working directory: %v\n", err)
		os.Exit(1)
	}

	var failures []string

	// --- Check 1: exported functions must have doc comments ----
	failures = append(failures, lintGoDocs(root)...)

	// --- Check 2: stale file references in backlog markdown ---
	if _, err := os.Stat(filepath.Join(root, ".private")); err == nil {
		failures = append(failures, lintStaleReferences(root)...)

		// --- Check 3: every backlog item file is indexed ---
		failures = append(failures, lintBacklogIndex(root)...)

		// --- Check 4: backlog YAML frontmatter status ---
		failures = append(failures, lintBacklogStatus(root)...)

		// --- Check 5: specialist protocol enforcement ---
		failures = append(failures, lintSpecialistProtocols(root)...)
	}

	if len(failures) > 0 {
		fmt.Fprintf(os.Stderr, "\n--- doc_lint: %d issue(s) found ---\n", len(failures))
		for _, f := range failures {
			fmt.Fprintln(os.Stderr, "  FAIL: "+f)
		}
		os.Exit(1)
	}

	fmt.Println("doc_lint: all checks passed")
}

// lintGoDocs walks Go source in internal/ and cmd/ and reports exported
// standalone functions that lack a doc comment.
func lintGoDocs(root string) []string {
	var out []string
	dirs := []string{
		filepath.Join(root, "internal"),
		filepath.Join(root, "cmd"),
	}

	for _, dir := range dirs {
		err := filepath.WalkDir(dir, func(path string, d os.DirEntry, err error) error {
			if err != nil {
				return nil
			}
			if d.IsDir() || !strings.HasSuffix(path, ".go") || strings.HasSuffix(path, "_test.go") {
				return nil
			}
			fset := token.NewFileSet()
			f, parseErr := parser.ParseFile(fset, path, nil, parser.ParseComments)
			if parseErr != nil {
				return nil
			}
			for _, decl := range f.Decls {
				fn, ok := decl.(*ast.FuncDecl)
				if !ok {
					continue
				}
				// Skip methods (functions with a receiver) — they often
				// implement interfaces and rarely need standalone docs.
				if fn.Recv != nil {
					continue
				}
				// Skip main — it's always the entry point and never needs a doc comment.
				if fn.Name.Name == "main" {
					continue
				}
				if !fn.Name.IsExported() {
					continue
				}
				if fn.Doc == nil || len(fn.Doc.List) == 0 {
					rel, _ := filepath.Rel(root, path)
					out = append(out, fmt.Sprintf("%s: exported func %s — missing doc comment", rel, fn.Name.Name))
				}
			}
			return nil
		})
		if err != nil {
			out = append(out, fmt.Sprintf("walking %s: %v", dir, err))
		}
	}
	return out
}

// pathRefRe matches Markdown inline-code that looks like a file path:
// contains a directory separator AND a recognized file extension.
var pathRefRe = regexp.MustCompile("`((?:[a-zA-Z0-9_.-]+/)+[a-zA-Z0-9_.-]+\\.(?:go|yml|yaml|json|md|ps1|sh|toml))`")

// lintStaleReferences scans non-archived .md files under .private/backlog/
// for backtick-quoted file paths and verifies each exists relative to root.
// This check is skipped in CI where .private/ is gitignored.
func lintStaleReferences(root string) []string {
	var out []string
	backlogDir := filepath.Join(root, ".private", "backlog")

	// In CI, .private/ is gitignored - skip this check gracefully
	if _, err := os.Stat(backlogDir); errors.Is(err, os.ErrNotExist) {
		return nil
	}

	filepath.WalkDir(backlogDir, func(path string, d os.DirEntry, err error) error {
		if err != nil || d.IsDir() || !strings.HasSuffix(path, ".md") {
			return nil
		}
		// Skip archived items — they are historical and may reference paths
		// that no longer exist.
		rel, _ := filepath.Rel(backlogDir, path)
		if strings.HasPrefix(rel, "archived"+string(filepath.Separator)) ||
			strings.Contains(rel, string(filepath.Separator)+"archived"+string(filepath.Separator)) {
			return nil
		}
		data, readErr := os.ReadFile(path)
		if readErr != nil {
			return nil
		}
		matches := pathRefRe.FindAllStringSubmatch(string(data), -1)
		for _, m := range matches {
			ref := m[1]
			absPath := filepath.Join(root, filepath.FromSlash(ref))
			if _, statErr := os.Stat(absPath); errors.Is(statErr, os.ErrNotExist) {
				relFile, _ := filepath.Rel(root, path)
				out = append(out, fmt.Sprintf("%s references non-existent path %q", relFile, ref))
			}
		}
		return nil
	})
	return out
}

// lintBacklogIndex ensures every .md in features/ and bugs/ is referenced
// (by filename) somewhere in BACKLOG.md.
// This check is skipped in CI where .private/ is gitignored.
func lintBacklogIndex(root string) []string {
	var out []string
	backlogMd := filepath.Join(root, ".private", "backlog", "BACKLOG.md")
	data, err := os.ReadFile(backlogMd)
	if err != nil {
		// In CI, .private/ is gitignored - skip this check gracefully
		if errors.Is(err, os.ErrNotExist) {
			return nil
		}
		out = append(out, fmt.Sprintf("cannot read BACKLOG.md: %v", err))
		return out
	}
	content := string(data)

	for _, subDir := range []string{"features", "bugs"} {
		dir := filepath.Join(root, ".private", "backlog", subDir)
		entries, _ := os.ReadDir(dir)
		for _, e := range entries {
			if e.IsDir() || !strings.HasSuffix(e.Name(), ".md") {
				continue
			}
			if !strings.Contains(content, e.Name()) {
				out = append(out,
					fmt.Sprintf("%s/%s is not referenced in BACKLOG.md", subDir, e.Name()))
			}
		}
	}
	return out
}

// frontmatterStatusRe matches the YAML status field in frontmatter.
var frontmatterStatusRe = regexp.MustCompile(`(?m)^status:\s*"?(.+?)"?\s*$`)

// validStatuses lists the allowed status values per the BACKLOG.md status key.
var validStatuses = map[string]bool{
	"Production":  true,
	"In Progress": true,
	"Planning":    true,
	"Draft":       true,
	"Archived":    true,
	"Resolved":    true,
}

// lintBacklogStatus checks that each backlog item has a valid YAML status.
// This check is skipped in CI where .private/ is gitignored.
func lintBacklogStatus(root string) []string {
	var out []string
	for _, subDir := range []string{"features", "bugs"} {
		dir := filepath.Join(root, ".private", "backlog", subDir)
		if _, err := os.Stat(dir); errors.Is(err, os.ErrNotExist) {
			return nil // In CI, .private/ is gitignored - skip gracefully
		}
		entries, _ := os.ReadDir(dir)
		for _, e := range entries {
			if e.IsDir() || !strings.HasSuffix(e.Name(), ".md") {
				continue
			}
			path := filepath.Join(dir, e.Name())
			data, err := os.ReadFile(path)
			if err != nil {
				continue
			}
			m := frontmatterStatusRe.FindSubmatch(data)
			if m == nil {
				out = append(out, fmt.Sprintf("%s/%s: missing or unparseable status field", subDir, e.Name()))
				continue
			}
			status := string(m[1])
			if !validStatuses[status] {
				out = append(out,
					fmt.Sprintf("%s/%s: invalid status %q (valid: Production, In Progress, Planning, Draft, Archived, Resolved)",
						subDir, e.Name(), status))
			}
		}
	}
	return out
}

// handoffRequiredFields lists mandatory keys in handoff.json.
var handoffRequiredFields = []string{
	"task_id", "source_specialist", "target_specialist",
	"state_file_path", "timestamp",
}

// staleLockAge is the threshold after which a lock file is considered stale.
const staleLockAge = 24 * time.Hour

// lintSpecialistProtocols validates handoff.json schema, checks for stale lock
// files, and ensures session state JSON is well-formed.
func lintSpecialistProtocols(root string) []string {
	var out []string
	sessionDir := filepath.Join(root, ".private", "session")
	locksDir := filepath.Join(root, ".private", "locks")

	// handoff.json schema validation.
	handoffPath := filepath.Join(sessionDir, "handoff.json")
	if data, err := os.ReadFile(handoffPath); err == nil {
		// Handle UTF-8 BOM
		data = []byte(strings.TrimPrefix(string(data), "\ufeff"))
		var obj map[string]json.RawMessage
		if jsonErr := json.Unmarshal(data, &obj); jsonErr != nil {
			out = append(out, fmt.Sprintf(".private/session/handoff.json: invalid JSON: %v", jsonErr))
		} else {
			for _, field := range handoffRequiredFields {
				if _, ok := obj[field]; !ok {
					out = append(out,
						fmt.Sprintf(".private/session/handoff.json: missing required field %q", field))
				}
			}
			// Verify task_id is NOT in archived (Production/Resolved).
			if raw, ok := obj["task_id"]; ok {
				var id string
				if json.Unmarshal(raw, &id) == nil {
					archivedDir := filepath.Join(root, ".private", "backlog", "archived")
					filepath.WalkDir(archivedDir, func(path string, d os.DirEntry, err error) error {
						if err != nil || d.IsDir() || !strings.Contains(d.Name(), id) {
							return nil
						}
						data, readErr := os.ReadFile(path)
						if readErr != nil {
							return nil
						}
						m := frontmatterStatusRe.FindSubmatch(data)
						if m != nil {
							status := string(m[1])
							if status == "Production" || status == "Resolved" {
								out = append(out, fmt.Sprintf(".private/session/handoff.json: task_id %q is already %s (archived)", id, status))
							}
						}
						return nil
					})
				}
			}

			// Verify state_file_path points to an existing file.
			if raw, ok := obj["state_file_path"]; ok {
				var p string
				if json.Unmarshal(raw, &p) == nil {
					abs := filepath.Join(root, filepath.FromSlash(p))
					if _, statErr := os.Stat(abs); errors.Is(statErr, os.ErrNotExist) {
						out = append(out,
							fmt.Sprintf(".private/session/handoff.json: state_file_path %q does not exist", p))
					}
				}
			}
		}
	}

	// session_state.json validity.
	statePath := filepath.Join(sessionDir, "session_state.json")
	if data, err := os.ReadFile(statePath); err == nil {
		// Handle UTF-8 BOM
		data = []byte(strings.TrimPrefix(string(data), "\ufeff"))
		var obj map[string]interface{}
		if jsonErr := json.Unmarshal(data, &obj); jsonErr != nil {
			out = append(out,
				fmt.Sprintf(".private/session/session_state.json: invalid JSON: %v", jsonErr))
		}
	}

	// Stale lock files.
	entries, err := os.ReadDir(locksDir)
	if err != nil {
		return out // no locks dir — not an error
	}
	now := time.Now()
	for _, e := range entries {
		if e.IsDir() {
			continue
		}
		info, infoErr := e.Info()
		if infoErr != nil {
			continue
		}
		if now.Sub(info.ModTime()) > staleLockAge {
			out = append(out,
				fmt.Sprintf(".private/locks/%s: lock file is stale (older than %s)",
					e.Name(), staleLockAge))
		}
	}
	return out
}
