//go:build ignore

// Command doc_lint checks that exported standalone functions in the gobot
// codebase have doc comments. It is designed to run in CI (< 30 s) and
// produces actionable, human-readable output.
package main

import (
	"fmt"
	"go/ast"
	"go/parser"
	"go/token"
	"os"
	"path/filepath"
	"strings"
)

func main() {
	root, err := os.Getwd()
	if err != nil {
		fmt.Fprintf(os.Stderr, "cannot determine working directory: %v\n", err)
		os.Exit(1)
	}

	failures := lintGoDocs(root)

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
				// Skip methods — they often implement interfaces and rarely need standalone docs.
				if fn.Recv != nil {
					continue
				}
				// Skip main — it's always the entry point.
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
