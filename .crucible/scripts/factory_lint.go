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
//  5. Every phase prompt carries the mandatory policy enforcement block.
//  6. Every phase prompt and SOP routes handoffs through new-handoff.ps1.
//  7. No committable files under a stray .crucible/ at the framework repo root.
//
// The budget-tier comparison that used to live here is gone. It sourced its
// expectation from the docs/policy.md table by regex, never matched, and reported
// success on every run since the initial commit; the tiers are now generated into the
// docs by powershell/gates/check-generated-docs.ps1 and verified by byte comparison.
package main

import (
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"os"
	"os/exec"
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
	frameworkRoot := flag.String("framework-root", projectRoot,
		"root of the Crucible framework checkout (defaults to the working directory)")
	backlogDir := flag.String("backlog-dir", "",
		"resolved backlog directory; required, obtain it from powershell/resolve-config-path.ps1")
	flag.Parse()

	// The backlog path is an input, not something this tool re-derives. Resolving it
	// here needed a second config parser, and that parser is what let a custom
	// paths.backlog silently disable all three backlog lints: it fell back to the
	// default directory, found nothing there, and reported success. Requiring the
	// caller to state the path removes the parser and the failure mode with it.
	if strings.TrimSpace(*backlogDir) == "" {
		fmt.Fprintln(os.Stderr, "factory_lint: -backlog-dir is required")
		flag.Usage()
		os.Exit(2)
	}

	var failures []string
	failures = append(failures, lintStaleReferences(projectRoot, *backlogDir)...)
	failures = append(failures, lintBacklogIndex(*backlogDir)...)
	failures = append(failures, lintBacklogStatus(*backlogDir)...)
	failures = append(failures, lintSpecialistProtocols(projectRoot)...)
	failures = append(failures, lintHandoffSchemaContracts(*frameworkRoot)...)
	failures = append(failures, lintHandoffValidationFixtures(*frameworkRoot)...)
	failures = append(failures, lintPromptPolicyBlocks(*frameworkRoot)...)
	failures = append(failures, lintPhaseDocHandoffTool(*frameworkRoot)...)
	failures = append(failures, lintTestPollution(*frameworkRoot)...)
	failures = append(failures, lintDebugPrints(*frameworkRoot)...)
	failures = append(failures, lintFactorySelfReference(*frameworkRoot)...)
	failures = append(failures, lintRegexHygiene(*frameworkRoot)...)

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

// lintStaleReferences scans non-archived .md files under backlogDir for
// backtick-quoted file paths and verifies each exists relative to root.
func lintStaleReferences(root string, backlogDir string) []string {
	var out []string
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
func lintBacklogIndex(backlogDir string) []string {
	var out []string
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
func lintBacklogStatus(backlogDir string) []string {
	var out []string
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
	"task_id", "source_phase", "target_phase",
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

		source := readConstFromProps(props, "source_phase")
		target := readConstFromProps(props, "target_phase")

		if source != "" {
			roleClauseSeen[source] = true
		}

		required := readStringArray(thenNode["required"])
		switch source {
		case "research":
			if !slices.Contains(required, "human_decisions") {
				out = append(out, "schemas/handoff.schema.json: research clause must require human_decisions")
			}
		case "grooming":
			// file_affinity is required only for grooming->implementation (Stub-Only Close-Out omits it).
			// Check that a dedicated grooming->implementation clause requiring file_affinity exists.
			if target == "implementation" && !slices.Contains(required, "file_affinity") {
				out = append(out, "schemas/handoff.schema.json: grooming->implementation clause must require file_affinity")
			}
		case "implementation", "deployment":
			if !slices.Contains(required, "session_cycle_id") {
				out = append(out, fmt.Sprintf("schemas/handoff.schema.json: %s clause must require session_cycle_id", source))
			}
		case "verification":
			if slices.Contains(required, "session_cycle_id") {
				reviewerSessionCycleRequired = true
			}
		}

		if source == "verification" && target == "deployment" {
			reviewerApprovalClause = true
			if slices.Contains(required, "reviewer_checks_passed") {
				reviewerContractField = true
			}
		}
	}

	for _, role := range []string{"research", "grooming", "implementation", "verification", "deployment"} {
		if !roleClauseSeen[role] {
			out = append(out, fmt.Sprintf("schemas/handoff.schema.json: missing phase-conditional clause for source_phase=%s", role))
		}
	}
	if !reviewerApprovalClause {
		out = append(out, "schemas/handoff.schema.json: missing verification->deployment contract clause")
	} else if !reviewerContractField {
		out = append(out, "schemas/handoff.schema.json: verification->deployment clause must require reviewer_checks_passed")
	}
	if !reviewerSessionCycleRequired {
		out = append(out, "schemas/handoff.schema.json: verification contract must require session_cycle_id")
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

	roles := []string{"research", "grooming", "implementation", "verification", "deployment"}
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
			if raw, ok := fixture["source_phase"]; ok {
				_ = json.Unmarshal(raw, &srcStr)
			}
			if srcStr != role {
				out = append(out, fmt.Sprintf(".crucible/session/fixtures/handoff-validation/%s: source_phase must be %q", name, role))
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

// phaseDocs are the per-phase prompt templates and SOPs. The three lints below key
// off this one list rather than each enumerating by pattern, and a listed file that
// does not exist is a failure. check-policy-drift.ps1 wrapped the equivalent loop in
// `if (Test-Path $fullPath)`, so a renamed doc removed its own coverage silently.
var phaseDocs = []string{
	"prompts/research_prompt.md",
	"prompts/grooming_prompt.md",
	"prompts/implementation_prompt.md",
	"prompts/verification_prompt.md",
	"prompts/deployment_prompt.md",
	"sops/research.md",
	"sops/grooming.md",
	"sops/implementation.md",
	"sops/verification.md",
	"sops/deployment.md",
}

const policyEnforcementHeading = "## POLICY ENFORCEMENT (Mandatory)"

// directHandoffWriteRe matches an instruction to write a handoff JSON by hand, which
// bypasses new-handoff.ps1 and its schema validation.
var directHandoffWriteRe = regexp.MustCompile("(?i)Write\\s+`[^`]*(?:handoffs/[^`]*\\.json|handoff\\.json)`")

// requiredPromptFiles returns the prompts/ entries of phaseDocs, by base name.
func requiredPromptFiles() []string {
	var out []string
	for _, rel := range phaseDocs {
		if name, ok := strings.CutPrefix(rel, "prompts/"); ok {
			out = append(out, name)
		}
	}
	return out
}

// lintPromptPolicyBlocks verifies that every phase prompt carries the mandatory policy
// enforcement heading, and that the enumeration found the prompts it was supposed to.
// The cardinality pin is the point: this check reads its subject set from the
// filesystem, and an enumeration that matches nothing otherwise passes - the same
// "found nothing, therefore fine" shape as the tier regex it replaced.
func lintPromptPolicyBlocks(root string) []string {
	var out []string
	promptDir := filepath.Join(root, "prompts")
	entries, err := os.ReadDir(promptDir)
	if err != nil {
		return []string{fmt.Sprintf("prompts/: cannot enumerate prompt templates: %v", err)}
	}

	seen := map[string]bool{}
	for _, e := range entries {
		if e.IsDir() || !strings.HasSuffix(e.Name(), "_prompt.md") {
			continue
		}
		seen[e.Name()] = true
		data, readErr := os.ReadFile(filepath.Join(promptDir, e.Name()))
		if readErr != nil {
			out = append(out, fmt.Sprintf("prompts/%s: cannot read: %v", e.Name(), readErr))
			continue
		}
		if !strings.Contains(string(data), policyEnforcementHeading) {
			out = append(out, fmt.Sprintf("prompts/%s: missing mandatory Policy Enforcement block", e.Name()))
		}
	}

	for _, name := range requiredPromptFiles() {
		if !seen[name] {
			out = append(out, fmt.Sprintf("prompts/%s: expected phase prompt was not found, so nothing checked it for the Policy Enforcement block", name))
		}
	}
	return out
}

// lintPhaseDocHandoffTool asserts that every phase prompt and SOP routes handoffs
// through new-handoff.ps1 and none of them instructs writing the JSON directly.
func lintPhaseDocHandoffTool(root string) []string {
	var out []string
	for _, rel := range phaseDocs {
		data, err := os.ReadFile(filepath.Join(root, filepath.FromSlash(rel)))
		if err != nil {
			out = append(out, fmt.Sprintf("%s: cannot read phase doc: %v", rel, err))
			continue
		}
		content := string(data)
		if directHandoffWriteRe.MatchString(content) {
			out = append(out, fmt.Sprintf("%s: instructs writing handoff JSON directly instead of using new-handoff.ps1", rel))
		}
		if !strings.Contains(content, "new-handoff.ps1") {
			out = append(out, fmt.Sprintf("%s: missing reference to new-handoff.ps1", rel))
		}
	}
	return out
}

// lintTestPollution fails when committable files sit under a stray .crucible/ at the
// framework repo root. This is framework test hygiene rather than policy - it means a
// test wrote its runtime state into the checkout instead of an isolated temp dir - and
// it was filed under "policy drift" only because that is where it was written.
//
// It keys off the framework root, never the working directory. In an adopter a root
// .crucible/ is the product, not pollution; there the framework root is that bundle
// and .crucible/.crucible does not exist, so this correctly finds nothing.
func lintTestPollution(root string) []string {
	if _, err := os.Stat(filepath.Join(root, ".crucible")); err != nil {
		return nil
	}
	// Outside a work tree nothing can be committed, so the condition does not apply.
	// This is not a fail-open: the check has an answer, and the answer is "clean".
	if err := exec.Command("git", "-C", root, "rev-parse", "--is-inside-work-tree").Run(); err != nil {
		return nil
	}

	var committable []string
	for _, args := range [][]string{
		{"ls-files", "--", ".crucible"},
		{"ls-files", "--others", "--exclude-standard", "--", ".crucible"},
	} {
		out, err := exec.Command("git", append([]string{"-C", root}, args...)...).Output()
		if err != nil {
			return []string{fmt.Sprintf(".crucible: cannot enumerate a stray root .crucible (git %s): %v", strings.Join(args, " "), err)}
		}
		for line := range strings.SplitSeq(string(out), "\n") {
			if trimmed := strings.TrimSpace(line); trimmed != "" {
				committable = append(committable, trimmed)
			}
		}
	}
	if len(committable) == 0 {
		return nil
	}

	shown := committable
	if len(shown) > 10 {
		shown = shown[:10]
	}
	return []string{fmt.Sprintf(".crucible: test pollution - %d committable file(s) under a stray root .crucible (%s); tests must write runtime state to isolated temp dirs",
		len(committable), strings.Join(shown, ", "))}
}

// collectRoleRequiredFields reads the schema and returns, per source_phase,
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
		source := readConstFromProps(props, "source_phase")
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

// lintRegexHygiene ensures no script file contains literal '(m) or "(m) regex flags.
func lintRegexHygiene(root string) []string {
	var out []string
	searchDirs := []string{
		filepath.Join(root, "powershell"),
		filepath.Join(root, "scripts"),
	}

	for _, dir := range searchDirs {
		if _, err := os.Stat(dir); errors.Is(err, os.ErrNotExist) {
			continue
		}
		filepath.WalkDir(dir, func(path string, d os.DirEntry, err error) error {
			if err != nil || d.IsDir() {
				return nil
			}
			ext := strings.ToLower(filepath.Ext(path))
			if ext != ".ps1" && ext != ".go" {
				return nil
			}
			if filepath.Base(path) == "regex-hygiene.tests.ps1" || filepath.Base(path) == "factory_lint.go" {
				return nil
			}
			data, readErr := os.ReadFile(path)
			if readErr != nil {
				return nil
			}
			content := string(data)
			containsM1 := "'" + "(" + "m" + ")"
			containsM2 := "\"" + "(" + "m" + ")"
			if strings.Contains(content, containsM1) || strings.Contains(content, containsM2) {
				relFile, _ := filepath.Rel(root, path)
				out = append(out, fmt.Sprintf("%s: contains literal '(m) or \"(m) regex flag", relFile))
			}
			return nil
		})
	}
	return out
}
