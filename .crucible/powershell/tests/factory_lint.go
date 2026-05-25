//go:build ignore

// Command factory_lint validates dev factory operational data integrity.
// It is called from the project's pre-commit hook whenever .crucible/ is present.
//
// Checks performed:
//  1. Non-archived backlog markdown files may reference file paths; every
//     referenced path that looks like a project file must exist.
//  2. Every .md file in .crucible/backlog/features/, bugs/, and chores/ must
//     be mentioned (by filename) in BACKLOG.md.
//  3. Backlog item YAML frontmatter must contain a valid status field.
//  4. Specialist protocol enforcement: handoff schema, stale locks, session JSON.
//  5. Policy drift: ensure factory logic and prompts match POLICY.md.
package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"slices"
	"strings"
	"time"
)

func main() {
	projectRoot, err := os.Getwd()
	if err != nil {
		fmt.Fprintf(os.Stderr, "cannot determine working directory: %v\n", err)
		os.Exit(1)
	}
	frameworkRoot := projectRoot
	if len(os.Args) > 1 && strings.TrimSpace(os.Args[1]) != "" {
		frameworkRoot = os.Args[1]
	}

	var failures []string
	failures = append(failures, lintStaleReferences(projectRoot)...)
	failures = append(failures, lintBacklogIndex(projectRoot)...)
	failures = append(failures, lintBacklogStatus(projectRoot)...)
	failures = append(failures, lintSpecialistProtocols(projectRoot)...)
	failures = append(failures, lintHandoffSchemaContracts(frameworkRoot)...)
	failures = append(failures, lintHandoffValidationFixtures(frameworkRoot)...)
	failures = append(failures, lintPolicyDrift(frameworkRoot)...)
	failures = append(failures, lintDebugPrints(frameworkRoot)...)
	failures = append(failures, lintFactorySelfReference(frameworkRoot)...)

	if len(failures) > 0 {
		fmt.Fprintf(os.Stderr, "\n--- factory_lint: %d issue(s) found ---\n", len(failures))
		for _, f := range failures {
			fmt.Fprintln(os.Stderr, "  FAIL: "+f)
		}
		os.Exit(1)
	}

	fmt.Println("factory_lint: all checks passed")
}

// pathRefRe matches Markdown inline-code that looks like a file path:
// contains a directory separator AND a recognized file extension.
var pathRefRe = regexp.MustCompile("`((?:[a-zA-Z0-9_.-]+/)+[a-zA-Z0-9_.-]+\\.(?:go|yml|yaml|json|md|ps1|sh|toml))`")

func getBacklogDir(root string) string {
	configPath := filepath.Join(root, ".crucible", "config.yaml")
	data, err := os.ReadFile(configPath)
	if err == nil {
		content := string(data)
		pathsBlockRe := regexp.MustCompile(`(?ms)^paths:\s*\r?\n(.*?)(?:\r?\n\S|\z)`)
		if m := pathsBlockRe.FindStringSubmatch(content); len(m) > 1 {
			backlogRe := regexp.MustCompile(`(?m)^\s{2}backlog:\s*["']?([^"'\r\n]+)["']?\s*$`)
			if bm := backlogRe.FindStringSubmatch(m[1]); len(bm) > 1 {
				val := strings.TrimSpace(bm[1])
				if filepath.IsAbs(val) {
					return val
				}
				return filepath.Join(root, filepath.FromSlash(val))
			}
		}
	}
	return filepath.Join(root, ".crucible", "backlog")
}

// lintStaleReferences scans non-archived .md files under the resolved backlog directory
// for backtick-quoted file paths and verifies each exists relative to root.
func lintStaleReferences(root string) []string {
	var out []string
	backlogDir := getBacklogDir(root)
	if _, err := os.Stat(backlogDir); errors.Is(err, os.ErrNotExist) {
		return nil
	}

	filepath.WalkDir(backlogDir, func(path string, d os.DirEntry, err error) error {
		if err != nil || d.IsDir() || !strings.HasSuffix(path, ".md") {
			return nil
		}
		rel, _ := filepath.Rel(backlogDir, path)
		lowerRel := strings.ToLower(rel)
		if strings.Contains(lowerRel, string(filepath.Separator)+"archive"+string(filepath.Separator)) ||
			strings.Contains(lowerRel, string(filepath.Separator)+"archived"+string(filepath.Separator)) ||
			strings.HasPrefix(lowerRel, "archive"+string(filepath.Separator)) ||
			strings.HasPrefix(lowerRel, "archived"+string(filepath.Separator)) {
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

// lintBacklogIndex ensures every .md in features/, bugs/, and chores/ is
// referenced (by filename) somewhere in BACKLOG.md.
func lintBacklogIndex(root string) []string {
	var out []string
	backlogDir := getBacklogDir(root)
	backlogMd := filepath.Join(backlogDir, "BACKLOG.md")
	data, err := os.ReadFile(backlogMd)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return nil
		}
		out = append(out, fmt.Sprintf("cannot read BACKLOG.md: %v", err))
		return out
	}
	content := string(data)

	for _, subDir := range []string{"features", "bugs", "chores"} {
		dir := filepath.Join(backlogDir, subDir, "active")
		if _, err := os.Stat(dir); errors.Is(err, os.ErrNotExist) {
			continue
		}
		entries, _ := os.ReadDir(dir)
		for _, e := range entries {
			if e.IsDir() || !strings.HasSuffix(e.Name(), ".md") {
				continue
			}
			if !strings.Contains(content, e.Name()) {
				out = append(out,
					fmt.Sprintf("%s/active/%s is not referenced in BACKLOG.md", subDir, e.Name()))
			}
		}
	}
	return out
}

// frontmatterStatusRe matches the YAML status field in frontmatter.
var frontmatterStatusRe = regexp.MustCompile(`(?m)^status:\s*"?(.+?)"?\s*$`)

// validStatuses lists the allowed status values.
var validStatuses = map[string]bool{
	"Stub":             true,
	"Production":       true,
	"In Progress":      true,
	"Planning":         true,
	"Draft":            true,
	"Archived":         true,
	"Resolved":         true,
	"Ready":            true,
	"Ready for Review": true,
	"Ready for Deploy": true,
}

// lintBacklogStatus checks that each backlog item has a valid YAML status.
func lintBacklogStatus(root string) []string {
	var out []string
	backlogDir := getBacklogDir(root)
	for _, subDir := range []string{"features", "bugs", "chores"} {
		dir := filepath.Join(backlogDir, subDir, "active")
		if _, err := os.Stat(dir); errors.Is(err, os.ErrNotExist) {
			continue
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
				out = append(out, fmt.Sprintf("%s/active/%s: missing or unparseable status field", subDir, e.Name()))
				continue
			}
			status := string(m[1])
			if !validStatuses[status] {
				out = append(out,
					fmt.Sprintf("%s/active/%s: invalid status %q (valid: Stub, Production, In Progress, Planning, Draft, Archived, Resolved, Ready, Ready for Review, Ready for Deploy)",
						subDir, e.Name(), status))
			}
		}
	}
	return out
}

// handoffRequiredFields lists mandatory keys in handoff JSON files.
var handoffRequiredFields = []string{
	"task_id", "source_specialist", "target_specialist",
	"prompt_version", "cumulative_handoff_count",
}

// staleLockAge is the threshold after which a lock file is considered stale.
const staleLockAge = 10 * time.Minute

// lintSpecialistProtocols validates handoff JSON files, checks for stale lock
// files, and ensures session state JSON is well-formed.
func lintSpecialistProtocols(root string) []string {
	var out []string
	sessionDir := filepath.Join(root, ".crucible", "session")
	handoffsDir := filepath.Join(sessionDir, "handoffs")
	globalDir := filepath.Join(sessionDir, "global")

	// Handoff JSON schema validation.
	if entries, err := os.ReadDir(handoffsDir); err == nil {
		for _, e := range entries {
			if e.IsDir() || !strings.HasSuffix(e.Name(), ".json") {
				continue
			}
			path := filepath.Join(handoffsDir, e.Name())
			data, err := os.ReadFile(path)
			if err != nil {
				continue
			}
			data = []byte(strings.TrimPrefix(string(data), "\ufeff"))
			var obj map[string]json.RawMessage
			if jsonErr := json.Unmarshal(data, &obj); jsonErr != nil {
				out = append(out, fmt.Sprintf(".crucible/session/handoffs/%s: invalid JSON: %v", e.Name(), jsonErr))
			} else {
				for _, field := range handoffRequiredFields {
					if _, ok := obj[field]; !ok {
						out = append(out,
							fmt.Sprintf(".crucible/session/handoffs/%s: missing required field %q", e.Name(), field))
					}
				}
			}
		}
	}

	// Session state JSON validity.
	statePath := filepath.Join(globalDir, "session_state.json")
	if data, err := os.ReadFile(statePath); err == nil {
		data = []byte(strings.TrimPrefix(string(data), "\ufeff"))
		var obj map[string]interface{}
		if jsonErr := json.Unmarshal(data, &obj); jsonErr != nil {
			out = append(out,
				fmt.Sprintf(".crucible/session/global/session_state.json: invalid JSON: %v", jsonErr))
		}
	}

	// Stale lock detection.
	if info, err := os.Stat(filepath.Join(globalDir, "session_state.lock")); err == nil {
		if !info.IsDir() && time.Since(info.ModTime()) > staleLockAge {
			out = append(out, fmt.Sprintf(".crucible/session/global/session_state.lock: stale lock detected (age: %v)", time.Since(info.ModTime())))
		}
	}
	return out
}

func lintHandoffSchemaContracts(root string) []string {
	var out []string
	schemaPath := filepath.Join(root, "schemas", "handoff.schema.json")
	data, err := os.ReadFile(schemaPath)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return nil
		}
		return []string{fmt.Sprintf("schemas/handoff.schema.json: cannot read: %v", err)}
	}
	var schema map[string]interface{}
	if err := json.Unmarshal(data, &schema); err != nil {
		return []string{fmt.Sprintf("schemas/handoff.schema.json: invalid JSON: %v", err)}
	}

	allOf, _ := schema["allOf"].([]interface{})
	roleClauseSeen := map[string]bool{}
	reviewerApprovalClause := false
	reviewerContractField := false
	reviewerSessionCycleRequired := false

	for _, raw := range allOf {
		clause, ok := raw.(map[string]interface{})
		if !ok {
			continue
		}
		ifNode, _ := clause["if"].(map[string]interface{})
		thenNode, _ := clause["then"].(map[string]interface{})
		if ifNode == nil || thenNode == nil {
			continue
		}
		props, _ := ifNode["properties"].(map[string]interface{})
		if props == nil {
			continue
		}

		source := readConstFromProps(props, "source_specialist")
		target := readConstFromProps(props, "target_specialist")

		if source != "" {
			roleClauseSeen[source] = true
		}

		required := readStringArray(thenNode["required"])
		switch source {
		case "researcher":
			if !slices.Contains(required, "human_decisions") {
				out = append(out, "schemas/handoff.schema.json: researcher clause must require human_decisions")
			}
		case "groomer":
			// file_affinity is required only for groomer->architect (Pattern C omits it).
			// Check that a dedicated groomer->architect clause requiring file_affinity exists.
			if target == "architect" && !slices.Contains(required, "file_affinity") {
				out = append(out, "schemas/handoff.schema.json: groomer->architect clause must require file_affinity")
			}
		case "architect", "operator":
			if !slices.Contains(required, "session_cycle_id") {
				out = append(out, fmt.Sprintf("schemas/handoff.schema.json: %s clause must require session_cycle_id", source))
			}
		case "reviewer":
			if slices.Contains(required, "session_cycle_id") {
				reviewerSessionCycleRequired = true
			}
		}

		if source == "reviewer" && target == "operator" {
			reviewerApprovalClause = true
			if slices.Contains(required, "reviewer_checks_passed") {
				reviewerContractField = true
			}
		}
	}

	for _, role := range []string{"researcher", "groomer", "architect", "reviewer", "operator"} {
		if !roleClauseSeen[role] {
			out = append(out, fmt.Sprintf("schemas/handoff.schema.json: missing role-conditional clause for source_specialist=%s", role))
		}
	}
	if !reviewerApprovalClause {
		out = append(out, "schemas/handoff.schema.json: missing reviewer->operator contract clause")
	} else if !reviewerContractField {
		out = append(out, "schemas/handoff.schema.json: reviewer->operator clause must require reviewer_checks_passed")
	}
	if !reviewerSessionCycleRequired {
		out = append(out, "schemas/handoff.schema.json: reviewer contract must require session_cycle_id")
	}

	return out
}

func lintHandoffValidationFixtures(root string) []string {
	var out []string
	fixturesDir := filepath.Join(root, ".crucible", "session", "fixtures", "handoff-validation")
	if _, err := os.Stat(fixturesDir); errors.Is(err, os.ErrNotExist) {
		return nil
	}

	roleRequired := collectRoleRequiredFields(root)

	roles := []string{"researcher", "groomer", "architect", "reviewer", "operator"}
	for _, role := range roles {
		required := roleRequired[role]
		for _, suffix := range []string{"valid", "invalid"} {
			name := fmt.Sprintf("%s-%s.json", role, suffix)
			path := filepath.Join(fixturesDir, name)
			data, err := os.ReadFile(path)
			if err != nil {
				out = append(out, fmt.Sprintf(".crucible/session/fixtures/handoff-validation/%s: missing fixture", name))
				continue
			}

			var fixture map[string]json.RawMessage
			if err := json.Unmarshal(data, &fixture); err != nil {
				out = append(out, fmt.Sprintf(".crucible/session/fixtures/handoff-validation/%s: invalid JSON: %v", name, err))
				continue
			}

			var srcStr string
			if raw, ok := fixture["source_specialist"]; ok {
				_ = json.Unmarshal(raw, &srcStr)
			}
			if srcStr != role {
				out = append(out, fmt.Sprintf(".crucible/session/fixtures/handoff-validation/%s: source_specialist must be %q", name, role))
			}

			if suffix == "valid" {
				for _, field := range required {
					raw, present := fixture[field]
					if !present || isBlankRawValue(raw) {
						out = append(out, fmt.Sprintf(".crucible/session/fixtures/handoff-validation/%s: valid fixture is missing required field %q for role %s", name, field, role))
					}
				}
			} else {
				if len(required) > 0 {
					missingAny := false
					for _, field := range required {
						raw, present := fixture[field]
						if !present || isBlankRawValue(raw) {
							missingAny = true
							break
						}
					}
					if !missingAny {
						out = append(out, fmt.Sprintf(".crucible/session/fixtures/handoff-validation/%s: invalid fixture satisfies all role-required fields for %s — it must omit at least one to be a negative test case", name, role))
					}
				}
			}
		}
	}

	return out
}

// lintPolicyDrift ensures that the framework's orchestration logic and templates
// stay synchronized with the canonical docs/policy.md.
func lintPolicyDrift(root string) []string {
	var out []string
	policyPath := filepath.Join(root, "docs", "policy.md")
	data, err := os.ReadFile(policyPath)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return []string{"docs/policy.md: missing canonical policy file"}
		}
		return []string{fmt.Sprintf("docs/policy.md: cannot read: %v", err)}
	}
	policy := string(data)

	// 1. Check Budget Tiers in factory.ps1
	factoryPath := filepath.Join(root, "powershell", "factory.ps1")
	if factoryData, err := os.ReadFile(factoryPath); err == nil {
		factory := string(factoryData)

		tiers := []struct {
			name string
			re   *regexp.Regexp
		}{
			{"Low", regexp.MustCompile(`Token Budget \(Low\)\s*\|\s*(\d+)`)},
			{"Medium", regexp.MustCompile(`Token Budget \(Medium\)\s*\|\s*(\d+)`)},
			{"High", regexp.MustCompile(`Token Budget \(High\)\s*\|\s*(\d+)`)},
		}

		for _, t := range tiers {
			m := t.re.FindStringSubmatch(policy)
			if m != nil {
				val := m[1]
				var check string
				switch t.name {
				case "Low":
					check = fmt.Sprintf("$budgetCeilings = @{ low = %s;", val)
				case "Medium":
					check = fmt.Sprintf("medium = %s;", val)
				case "High":
					check = fmt.Sprintf("high = %s }", val)
				}
				if !strings.Contains(factory, check) {
					out = append(out, fmt.Sprintf("powershell/factory.ps1: budget tier %s mismatch with POLICY.md (expected %s)", t.name, val))
				}
			}
		}
	}

	// 2. Check Prompt Templates for Policy Enforcement block
	promptDir := filepath.Join(root, "prompts")
	if entries, err := os.ReadDir(promptDir); err == nil {
		for _, e := range entries {
			if e.IsDir() || !strings.HasSuffix(e.Name(), "_prompt.md") {
				continue
			}
			path := filepath.Join(promptDir, e.Name())
			if promptData, err := os.ReadFile(path); err == nil {
				if !strings.Contains(string(promptData), "## POLICY ENFORCEMENT (Mandatory)") {
					out = append(out, fmt.Sprintf("prompts/%s: missing mandatory Policy Enforcement block", e.Name()))
				}
			}
		}
	}

	return out
}

// collectRoleRequiredFields reads the schema and returns, per source_specialist,
// the list of fields that the allOf conditional clauses declare as required.
func collectRoleRequiredFields(root string) map[string][]string {
	result := map[string][]string{}
	schemaPath := filepath.Join(root, "schemas", "handoff.schema.json")
	data, err := os.ReadFile(schemaPath)
	if err != nil {
		return result
	}
	var schema map[string]interface{}
	if err := json.Unmarshal(data, &schema); err != nil {
		return result
	}
	allOf, _ := schema["allOf"].([]interface{})
	for _, raw := range allOf {
		clause, ok := raw.(map[string]interface{})
		if !ok {
			continue
		}
		ifNode, _ := clause["if"].(map[string]interface{})
		thenNode, _ := clause["then"].(map[string]interface{})
		if ifNode == nil || thenNode == nil {
			continue
		}
		props, _ := ifNode["properties"].(map[string]interface{})
		if props == nil {
			continue
		}
		source := readConstFromProps(props, "source_specialist")
		if source == "" {
			continue
		}
		for _, f := range readStringArray(thenNode["required"]) {
			if !slices.Contains(result[source], f) {
				result[source] = append(result[source], f)
			}
		}
	}
	return result
}

// isBlankRawValue reports whether a JSON raw value represents null, an empty
// string, or an empty array — all treated as "not meaningfully present".
func isBlankRawValue(raw json.RawMessage) bool {
	s := strings.TrimSpace(string(raw))
	return s == "null" || s == `""` || s == "[]"
}

func readConstFromProps(props map[string]interface{}, key string) string {
	raw, ok := props[key].(map[string]interface{})
	if !ok {
		return ""
	}
	v, _ := raw["const"].(string)
	return strings.TrimSpace(v)
}

func readStringArray(v interface{}) []string {
	list, ok := v.([]interface{})
	if !ok {
		return nil
	}
	out := make([]string, 0, len(list))
	for _, item := range list {
		s, ok := item.(string)
		if ok && strings.TrimSpace(s) != "" {
			out = append(out, strings.TrimSpace(s))
		}
	}
	return out
}

// lintDebugPrints ensures no powershell file contains Write-Host.*DEBUG: statements.
func lintDebugPrints(root string) []string {
	var out []string
	powershellDir := filepath.Join(root, "powershell")
	filepath.WalkDir(powershellDir, func(path string, d os.DirEntry, err error) error {
		if err != nil || d.IsDir() || !strings.HasSuffix(path, ".ps1") {
			return nil
		}
		// Skip files in directories we don't own or don't want to lint (e.g. adopter worktrees)
		if strings.Contains(path, ".agent-workspaces") {
			return nil
		}
		data, readErr := os.ReadFile(path)
		if readErr != nil {
			return nil
		}
		lines := strings.Split(string(data), "\n")
		debugRe := regexp.MustCompile(`(?i)Write-Host\s+.*DEBUG:`)
		for i, line := range lines {
			if debugRe.MatchString(line) {
				relFile, _ := filepath.Rel(root, path)
				out = append(out, fmt.Sprintf("%s:%d: forbidden Write-Host DEBUG print statement", relFile, i+1))
			}
		}
		return nil
	})
	return out
}

// lintFactorySelfReference ensures factory.ps1 does not hardcode "powershell/factory.ps1"
func lintFactorySelfReference(root string) []string {
	var out []string
	factoryPath := filepath.Join(root, "powershell", "factory.ps1")
	data, err := os.ReadFile(factoryPath)
	if err != nil {
		return nil
	}
	lines := strings.Split(string(data), "\n")
	for i, line := range lines {
		if strings.Contains(line, "powershell/factory.ps1") && !strings.Contains(line, "crucibleRoot") {
			out = append(out, fmt.Sprintf("powershell/factory.ps1:%d: hardcoded \"powershell/factory.ps1\" path detected. Prepend with crucible_root configuration instead", i+1))
		}
	}
	return out
}
