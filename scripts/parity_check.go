//go:build ignore

// Command parity_check validates that implementation tags declared in
// UPSTREAM_REFERENCES.md have matching occurrences in the Go source tree.
//
// Tags are denoted by lines like:
//
//	<!-- tag: FOO_BAR -->
//
// The checker scans all .go files under internal/ and cmd/ for the tag
// identifier (e.g. "FOO_BAR") and reports any tag that has zero matches.
//
// If UPSTREAM_REFERENCES.md does not exist the tool exits successfully with
// a message (0 tags = nothing to check).
package main

import (
	"bufio"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"
)

// tagRe matches HTML comments of the form <!-- tag: IDENTIFIER -->.
var tagRe = regexp.MustCompile(`<!--\s*tag:\s*(\S+)\s*-->`)

func main() {
	root, err := os.Getwd()
	if err != nil {
		fmt.Fprintf(os.Stderr, "cannot determine working directory: %v\n", err)
		os.Exit(1)
	}

	refFile := filepath.Join(root, "UPSTREAM_REFERENCES.md")
	f, err := os.Open(refFile)
	if err != nil {
		if os.IsNotExist(err) {
			fmt.Println("parity_check: UPSTREAM_REFERENCES.md not found — skipping (0 tags)")
			return
		}
		fmt.Fprintf(os.Stderr, "cannot open UPSTREAM_REFERENCES.md: %v\n", err)
		os.Exit(1)
	}
	defer f.Close()

	// Parse tags.
	var tags []string
	scanner := bufio.NewScanner(f)
	for scanner.Scan() {
		m := tagRe.FindStringSubmatch(scanner.Text())
		if m != nil {
			tags = append(tags, m[1])
		}
	}

	if len(tags) == 0 {
		fmt.Println("parity_check: no tags found in UPSTREAM_REFERENCES.md")
		return
	}

	// Collect all Go source text once.
	var src strings.Builder
	for _, dir := range []string{filepath.Join(root, "internal"), filepath.Join(root, "cmd")} {
		filepath.WalkDir(dir, func(path string, d os.DirEntry, walkErr error) error {
			if walkErr != nil || d.IsDir() || !strings.HasSuffix(path, ".go") || strings.HasSuffix(path, "_test.go") {
				return nil
			}
			data, readErr := os.ReadFile(path)
			if readErr == nil {
				src.Write(data)
			}
			return nil
		})
	}

	srcText := src.String()
	var missing []string
	for _, tag := range tags {
		if !strings.Contains(srcText, tag) {
			missing = append(missing, tag)
		}
	}

	if len(missing) > 0 {
		fmt.Fprintf(os.Stderr, "\n--- parity_check: %d tag(s) missing from codebase ---\n", len(missing))
		for _, t := range missing {
			fmt.Fprintf(os.Stderr, "  MISSING: %s\n", t)
		}
		os.Exit(1)
	}

	fmt.Printf("parity_check: all %d tag(s) found in codebase\n", len(tags))
}
