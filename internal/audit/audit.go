// Package audit classifies Gemini models into strategic tiers and builds
// Markdown audit reports (F-043 port). No I/O — all side effects live in
// the caller.
package audit

import (
	"strconv"
	"strings"
	"time"
)

// ModelInfo holds the fields needed from a Gemini API model object.
// Callers convert genai.ModelInfo → audit.ModelInfo before calling BuildReport.
type ModelInfo struct {
	Name        string
	DisplayName string
	Description string
}

// tierPattern maps a tier name to the substrings that identify it.
// Order matters — most specific patterns must come first.
var tierPatterns = []struct {
	tier     string
	keywords []string
}{
	{"researcher", []string{"flash-lite"}},
	{"architect", []string{"pro", "ultra"}},
	{"default", []string{"flash"}},
}

// specialKeywords identifies models that are not conversational agents.
var specialKeywords = []string{
	"embed", "aqa", "text-bison", "chat-bison", "vision",
	"imagen", "veo", "lyria", "gemma", "robotics",
	"computer-use", "deep-research", "tts", "audio",
}

// ClassifyModel returns the strategic tier for a Gemini model name.
// Returns one of: "researcher", "default", "architect", "special", "other".
func ClassifyModel(modelName string) string {
	name := strings.ToLower(strings.ReplaceAll(modelName, "models/", ""))
	for _, kw := range specialKeywords {
		if strings.Contains(name, kw) {
			return "special"
		}
	}
	for _, tp := range tierPatterns {
		for _, kw := range tp.keywords {
			if strings.Contains(name, kw) {
				return tp.tier
			}
		}
	}
	return "other"
}

// BuildReport builds a Markdown audit report comparing available models
// against the current config.
//
// current must have keys "default", "researcher", "architect" mapping to
// the currently configured model name for each role.
func BuildReport(models []ModelInfo, current map[string]string) string {
	today := time.Now().Format("2006-01-02")

	byTier := map[string][]ModelInfo{
		"researcher": {},
		"default":    {},
		"architect":  {},
		"special":    {},
		"other":      {},
	}
	for _, m := range models {
		tier := ClassifyModel(m.Name)
		byTier[tier] = append(byTier[tier], m)
	}

	bare := func(name string) string {
		return strings.ReplaceAll(name, "models/", "")
	}

	modelRow := func(m ModelInfo, currentName string) string {
		b := bare(m.Name)
		display := m.DisplayName
		if display == "" {
			display = b
		}
		desc := m.Description
		if len(desc) > 90 {
			desc = desc[:90]
		}
		desc = strings.ReplaceAll(desc, "|", `\|`)
		flag := ""
		if b == bare(currentName) {
			flag = " **[CURRENT]**"
		}
		return "| `" + b + "` | " + display + flag + " | " + desc + " |"
	}

	var lines []string
	add := func(s string) { lines = append(lines, s) }

	add("# F-043: Model Tier Audit Report")
	add("**Date:** " + today + "  ")
	add("**Available models:** " + strconv.Itoa(len(models)))
	add("")
	add("---")
	add("")
	add("## Current Configuration")
	add("")
	add("| Role | Model |")
	add("|------|-------|")
	add("| Default (Balanced) | `" + current["default"] + "` |")
	add("| Researcher (Budget) | `" + current["researcher"] + "` |")
	add("| Architect (Premium) | `" + current["architect"] + "` |")
	add("")
	add("---")
	add("")

	tierSections := []struct {
		key       string
		heading   string
		configKey string
	}{
		{"researcher", "Researcher Tier — Budget (`flash-lite` candidates)", "researcher"},
		{"default", "Default Tier — Balanced (`flash` candidates)", "default"},
		{"architect", "Architect Tier — Premium (`pro` / `ultra` candidates)", "architect"},
	}

	suggestions := map[string]string{}
	for _, ts := range tierSections {
		tierModels := byTier[ts.key]
		add("## " + ts.heading)
		add("")
		if len(tierModels) == 0 {
			add("*No models classified for this tier.*")
			add("")
			continue
		}
		add("| Model | Display Name | Notes |")
		add("|-------|-------------|-------|")
		for _, m := range tierModels {
			add(modelRow(m, current[ts.configKey]))
		}
		// Suggest replacement only if current model is absent (retirement awareness).
		tierBareNames := make([]string, len(tierModels))
		for i, m := range tierModels {
			tierBareNames[i] = bare(m.Name)
		}
		currentBare := bare(current[ts.configKey])
		if !contains(tierBareNames, currentBare) {
			suggestions[ts.configKey] = tierBareNames[0]
		}
		add("")
	}

	// Special / embedding / other
	specialModels := append(byTier["special"], byTier["other"]...) //nolint:gocritic // intentional: merge two slices into new slice
	add("## Special-Purpose & Embedding Models")
	add("")
	if len(specialModels) > 0 {
		add("| Model | Display Name |")
		add("|-------|-------------|")
		for _, m := range specialModels {
			b := bare(m.Name)
			display := m.DisplayName
			if display == "" {
				display = b
			}
			add("| `" + b + "` | " + display + " |")
		}
	} else {
		add("*None found.*")
	}
	add("")

	// Suggestions summary
	add("---")
	add("")
	add("## Suggested Updates")
	add("")
	if len(suggestions) > 0 {
		add("| Role | Current | Candidate |")
		add("|------|---------|-----------|")
		for role, candidate := range suggestions {
			add("| `" + role + "` | `" + current[role] + "` | `" + candidate + "` |")
		}
		add("")
		add("> **No changes are applied automatically.**")
		add("> Edit `~/.gobot/config.json` to apply updates.")
	} else {
		add("Current configuration already matches the best available candidates." +
			" No changes suggested.")
	}

	return strings.Join(lines, "\n")
}

func contains(slice []string, s string) bool {
	for _, v := range slice {
		if v == s {
			return true
		}
	}
	return false
}
