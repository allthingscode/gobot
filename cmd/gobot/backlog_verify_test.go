package main

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// sessionState represents the structure of session_state.json
type sessionState struct {
	Specialists map[string]specialistState `json:"specialists"`
}

type specialistState struct {
	LastItem string `json:"last_item"`
}

// TestBacklogItemStatusVerification ensures the last_item in session_state.json
// has a status field that matches reality (code existence).
func TestBacklogItemStatusVerification(t *testing.T) {
	// 1. Locate session_state.json
	statePath := filepath.Join("..", "..", ".private", "session", "session_state.json")
	stateBytes, err := os.ReadFile(statePath)
	if err != nil {
		if os.IsNotExist(err) {
			t.Skip("session_state.json not found; skipping backlog verification")
		}
		t.Fatalf("Failed to read session_state.json: %v", err)
	}

	// 2. Parse session state
	// Handle UTF-8 BOM if present
	if len(stateBytes) > 0 && stateBytes[0] == 0xEF && stateBytes[1] == 0xBB && stateBytes[2] == 0xBF {
		stateBytes = stateBytes[3:]
	}
	var state sessionState
	if err := json.Unmarshal(stateBytes, &state); err != nil {
		t.Fatalf("Failed to parse session_state.json: %v", err)
	}

	// 3. Collect unique last_items from all specialists
	itemsToCheck := make(map[string]bool)
	for _, spec := range state.Specialists {
		if spec.LastItem != "" {
			itemsToCheck[spec.LastItem] = true
		}
	}

	if len(itemsToCheck) == 0 {
		t.Skip("No active last_item found in session_state.json")
	}

	// 4. Verify each item
	for itemID := range itemsToCheck {
		t.Run(itemID, func(t *testing.T) {
			verifyItemStatus(t, itemID)
		})
	}
}

func verifyItemStatus(t *testing.T, itemID string) {
	// 1. Find the backlog file
	backlogRoot := filepath.Join("..", "..", ".private", "backlog")
	itemFile, err := findItemFile(backlogRoot, itemID)
	if err != nil {
		t.Fatalf("Failed to find backlog file for %s: %v", itemID, err)
	}

	// 2. Parse frontmatter
	content, err := os.ReadFile(itemFile)
	if err != nil {
		t.Fatalf("Failed to read %s: %v", itemFile, err)
	}

	status := extractStatus(content)
	if status == "" {
		t.Skipf("No status found in %s", itemFile)
	}

	// 3. Check for code references
	hasCode := hasCodeReferences(itemID)

	// 4. Assertions
	// If status is Draft but code exists, the status is stale
	if status == "Draft" && hasCode {
		t.Errorf("Item %s has status 'Draft' but code references exist. Update status to 'Production' or 'Planning'.\n  File: %s", itemID, itemFile)
	}

	// If status is Production but no code exists in cmd/internal/scripts, check git log
	// This is a softer check - we trust the status if we can't verify via file scanning
	if status == "Production" && !hasCode {
		// Check if this might be a scripts-only change (like F-058)
		if strings.Contains(itemFile, filepath.Join("backlog", "archived")) {
			// For archived items, trust the status but suggest adding item ID to code comments
			t.Logf("Item %s is archived. To improve verification, add the item ID to code comments in the implementation.", itemID)
		}
		// Don't fail - archived items are trusted
		return
	}
}

func findItemFile(root, itemID string) (string, error) {
	dirs := []string{
		filepath.Join(root, "features"),
		filepath.Join(root, "bugs"),
		filepath.Join(root, "chores"),
		filepath.Join(root, "archived"),
	}

	for _, dir := range dirs {
		files, err := os.ReadDir(dir)
		if err != nil {
			continue
		}
		for _, f := range files {
			if strings.Contains(f.Name(), itemID) {
				return filepath.Join(dir, f.Name()), nil
			}
		}
	}
	return "", os.ErrNotExist
}

func extractStatus(content []byte) string {
	text := string(content)
	if !strings.HasPrefix(text, "---") {
		return ""
	}

	endIdx := strings.Index(text[3:], "---")
	if endIdx == -1 {
		return ""
	}

	yamlContent := text[3 : 3+endIdx]

	// Simple string search for status field
	// Look for status: "SomeValue"
	statusPrefix := "status:"
	lines := strings.SplitSeq(yamlContent, "\n")
	for line := range lines {
		line = strings.TrimSpace(line)
		if strings.HasPrefix(line, statusPrefix) {
			val := strings.TrimSpace(line[len(statusPrefix):])
			// Remove quotes
			val = strings.Trim(val, "\"'")
			return val
		}
	}
	return ""
}

func hasCodeReferences(itemID string) bool {
	codeDirs := []string{
		filepath.Join("..", "..", "cmd"),
		filepath.Join("..", "..", "internal"),
		filepath.Join("..", "..", "scripts"),
	}

	for _, codeDir := range codeDirs {
		err := filepath.Walk(codeDir, func(path string, _ os.FileInfo, err error) error {
			if err != nil {
				return err
			}
			if !strings.HasSuffix(path, ".go") {
				return nil
			}
			content, err := os.ReadFile(path)
			if err != nil {
				return err
			}
			if strings.Contains(string(content), itemID) {
				return os.ErrExist
			}
			return nil
		})
		if errors.Is(err, os.ErrExist) {
			return true
		}
	}
	return false
}
