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
//
//nolint:gochecknoglobals // Immutable lookup table for model classification
var tierPatterns = []struct {
	tier     string
	keywords []string
}{
	{"researcher", []string{"flash-lite"}},
	{"architect", []string{"pro", "ultra"}},
	{"default", []string{"flash"}},
}

// specialKeywords identifies models that are not conversational agents.
//
//nolint:gochecknoglobals // Immutable lookup table for model classification
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
	byTier := groupByTier(models)
	suggestions := map[string]string{}
	var lines []string

	addReportHeader(&lines, len(models))
	addCurrentConfig(&lines, current)

	tierSections := []struct {
		key       string
		heading   string
		configKey string
	}{
		{"researcher", "Researcher Tier — Budget (`flash-lite` candidates)", "researcher"},
		{"default", "Default Tier — Balanced (`flash` candidates)", "default"},
		{"architect", "Architect Tier — Premium (`pro` / `ultra` candidates)", "architect"},
	}

	for _, ts := range tierSections {
		addTierSection(&lines, ts.heading, byTier[ts.key], current[ts.configKey], ts.configKey, suggestions)
	}

	addSpecialModels(&lines, byTier)
	addSuggestions(&lines, suggestions, current)

	return strings.Join(lines, "\n")
}

func groupByTier(models []ModelInfo) map[string][]ModelInfo {
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
	return byTier
}

func addReportHeader(lines *[]string, modelCount int) {
	today := time.Now().Format("2006-01-02")
	*lines = append(*lines, "# F-043: Model Tier Audit Report")
	*lines = append(*lines, "**Date:** "+today+"  ")
	*lines = append(*lines, "**Available models:** "+strconv.Itoa(modelCount))
	*lines = append(*lines, "")
	*lines = append(*lines, "---")
	*lines = append(*lines, "")
}

func addCurrentConfig(lines *[]string, current map[string]string) {
	*lines = append(*lines, "## Current Configuration")
	*lines = append(*lines, "")
	*lines = append(*lines, "| Role | Model |")
	*lines = append(*lines, "|------|-------|")
	*lines = append(*lines, "| Default (Balanced) | `"+current["default"]+"` |")
	*lines = append(*lines, "| Researcher (Budget) | `"+current["researcher"]+"` |")
	*lines = append(*lines, "| Architect (Premium) | `"+current["architect"]+"` |")
	*lines = append(*lines, "")
	*lines = append(*lines, "---")
	*lines = append(*lines, "")
}

func addTierSection(lines *[]string, heading string, tierModels []ModelInfo, currentName, configKey string, suggestions map[string]string) {
	*lines = append(*lines, "## "+heading)
	*lines = append(*lines, "")
	if len(tierModels) == 0 {
		*lines = append(*lines, "*No models classified for this tier.*")
		*lines = append(*lines, "")
		return
	}

	*lines = append(*lines, "| Model | Display Name | Notes |")
	*lines = append(*lines, "|-------|-------------|-------|")
	tierBareNames := make([]string, len(tierModels))
	for i, m := range tierModels {
		*lines = append(*lines, modelRow(m, currentName))
		tierBareNames[i] = bare(m.Name)
	}

	currentBare := bare(currentName)
	if !contains(tierBareNames, currentBare) && len(tierBareNames) > 0 {
		suggestions[configKey] = tierBareNames[0]
	}
	*lines = append(*lines, "")
}

func addSpecialModels(lines *[]string, byTier map[string][]ModelInfo) {
	specialModels := append(byTier["special"], byTier["other"]...) //nolint:gocritic // intentional merge
	*lines = append(*lines, "## Special-Purpose & Embedding Models")
	*lines = append(*lines, "")
	if len(specialModels) > 0 {
		*lines = append(*lines, "| Model | Display Name |")
		*lines = append(*lines, "|-------|-------------|")
		for _, m := range specialModels {
			b := bare(m.Name)
			display := m.DisplayName
			if display == "" {
				display = b
			}
			*lines = append(*lines, "| `"+b+"` | "+display+" |")
		}
	} else {
		*lines = append(*lines, "*None found.*")
	}
	*lines = append(*lines, "")
}

func addSuggestions(lines *[]string, suggestions, current map[string]string) {
	*lines = append(*lines, "---")
	*lines = append(*lines, "")
	*lines = append(*lines, "## Suggested Updates")
	*lines = append(*lines, "")
	if len(suggestions) > 0 {
		*lines = append(*lines, "| Role | Current | Candidate |")
		*lines = append(*lines, "|------|---------|-----------|")
		for role, candidate := range suggestions {
			*lines = append(*lines, "| `"+role+"` | `"+current[role]+"` | `"+candidate+"` |")
		}
		*lines = append(*lines, "")
		*lines = append(*lines, "> **No changes are applied automatically.**")
		*lines = append(*lines, "> Edit `~/.gobot/config.json` to apply updates.")
	} else {
		*lines = append(*lines, "Current configuration already matches the best available candidates. No changes suggested.")
	}
}

func bare(name string) string {
	return strings.ReplaceAll(name, "models/", "")
}

func modelRow(m ModelInfo, currentName string) string {
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

func contains(slice []string, s string) bool {
	for _, v := range slice {
		if v == s {
			return true
		}
	}
	return false
}
