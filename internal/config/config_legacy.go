package config

import (
	"encoding/json"
)

// DeprecatedKeyDiagnostic describes a deprecated config key normalized during load.
type DeprecatedKeyDiagnostic struct {
	Section       string
	DeprecatedKey string
	CanonicalKey  string
	Ignored       bool
}

// legacyKeyRenames is the SINGLE source of truth mapping deprecated snake_case config
// keys to their canonical camelCase form (C-326). The map key is the dot-joined path of
// the CONTAINING object (root object = ""); a trailing ".*" segment matches every entry
// of a JSON object used as a map (e.g. a named circuit breaker under
// resilience.circuitBreakers). The loader rewrites legacy keys to canonical before strict
// decoding so existing configs keep working during the deprecation window, while
// Config.Save only ever emits the canonical key. To end the deprecation window, delete
// this map and the normalizeLegacyKeys call in decode in one commit.
//
//nolint:gochecknoglobals // immutable lookup table for the key-deprecation window
var legacyKeyRenames = map[string]map[string]string{
	"": {
		// C-327: the legacy "strategic_edition" block was renamed to the neutral "runtime".
		"strategic_edition": "runtime",
	},
	"logging": {
		"max_size_mb":  "maxSizeMB",
		"max_backups":  "maxBackups",
		"max_age_days": "maxAgeDays",
	},
	"browser": {
		"debug_port": "debugPort",
	},
	"resilience": {
		"circuit_breakers": "circuitBreakers",
	},
	"resilience.circuitBreakers.*": {
		"max_failures": "maxFailures",
	},
	"context": {
		"session_token_budget":     "sessionTokenBudget",
		"compaction_summary_turns": "compactionSummaryTurns",
	},
	"gateway": {
		"dashboard_enabled": "dashboardEnabled",
		"auth_token":        "authToken",
		"web_addr":          "webAddr",
	},
	"tools": {
		"high_risk": "highRisk",
	},
}

// normalizeLegacyKeysWithDiagnostics rewrites deprecated snake_case keys and returns
// diagnostics for callers that render expected migration feedback intentionally.
func normalizeLegacyKeysWithDiagnostics(data []byte) ([]byte, []DeprecatedKeyDiagnostic) {
	var root map[string]json.RawMessage
	if err := json.Unmarshal(data, &root); err != nil {
		return data, nil
	}
	var diagnostics []DeprecatedKeyDiagnostic
	if !renameKeysAtPath(root, "", map[string]bool{}, &diagnostics) {
		return data, nil
	}
	out, err := json.Marshal(root)
	if err != nil {
		return data, nil
	}
	return out, diagnostics
}

// renameKeysAtPath applies the rules registered for obj's own path, then descends only
// into child objects that (or whose ".*" map entries) have their own rules. Returns true
// if any key was renamed in the subtree.
func renameKeysAtPath(obj map[string]json.RawMessage, path string, warned map[string]bool, diagnostics *[]DeprecatedKeyDiagnostic) bool {
	changed := false
	if renames, ok := legacyKeyRenames[path]; ok {
		changed = applyRenames(obj, path, renames, warned, diagnostics)
	}
	for childKey, childRaw := range obj {
		if descendChild(obj, childKey, childRaw, childPathOf(path, childKey), warned, diagnostics) {
			changed = true
		}
	}
	return changed
}

func childPathOf(path, childKey string) string {
	if path == "" {
		return childKey
	}
	return path + "." + childKey
}

// hasRuleForPath reports whether any rename rule applies at path, either directly or to
// the entries of a map at that path (".*").
func hasRuleForPath(path string) bool {
	if _, ok := legacyKeyRenames[path]; ok {
		return true
	}
	_, ok := legacyKeyRenames[path+".*"]
	return ok
}

// normalizeChild applies the direct and ".*" map-entry rules registered for childPath to
// an already-decoded child object. Returns true if anything changed.
func normalizeChild(child map[string]json.RawMessage, childPath string, warned map[string]bool, diagnostics *[]DeprecatedKeyDiagnostic) bool {
	changed := false
	if _, ok := legacyKeyRenames[childPath]; ok && renameKeysAtPath(child, childPath, warned, diagnostics) {
		changed = true
	}
	if wildRenames, ok := legacyKeyRenames[childPath+".*"]; ok && renameMapEntries(child, childPath+".*", wildRenames, warned, diagnostics) {
		changed = true
	}
	return changed
}

// descendChild recurses into a single child object when a rule applies at childPath,
// re-marshaling it back into parent on change.
func descendChild(parent map[string]json.RawMessage, childKey string, childRaw json.RawMessage, childPath string, warned map[string]bool, diagnostics *[]DeprecatedKeyDiagnostic) bool {
	if !hasRuleForPath(childPath) {
		return false
	}
	var child map[string]json.RawMessage
	if err := json.Unmarshal(childRaw, &child); err != nil || child == nil {
		return false
	}
	if !normalizeChild(child, childPath, warned, diagnostics) {
		return false
	}
	if rm, err := json.Marshal(child); err == nil {
		parent[childKey] = rm
	}
	return true
}

// renameMapEntries applies renames to every value of a JSON object used as a map (e.g.
// each named circuit breaker), re-marshaling changed entries in place.
func renameMapEntries(m map[string]json.RawMessage, path string, renames map[string]string, warned map[string]bool, diagnostics *[]DeprecatedKeyDiagnostic) bool {
	changed := false
	for k, raw := range m {
		var inner map[string]json.RawMessage
		if err := json.Unmarshal(raw, &inner); err != nil || inner == nil {
			continue
		}
		section := childPathOf(path[:len(path)-2], k)
		if applyRenames(inner, section, renames, warned, diagnostics) {
			if rm, err := json.Marshal(inner); err == nil {
				m[k] = rm
				changed = true
			}
		}
	}
	return changed
}

// applyRenames moves each present legacy key to its canonical key within obj, recording
// exactly one diagnostic per legacy key per load. When both keys are present the
// canonical value wins and the legacy key is dropped. Returns true if modified.
func applyRenames(obj map[string]json.RawMessage, path string, renames map[string]string, warned map[string]bool, diagnostics *[]DeprecatedKeyDiagnostic) bool {
	changed := false
	for legacy, canonical := range renames {
		val, present := obj[legacy]
		if !present {
			continue
		}
		warnKey := path + "/" + legacy
		_, hasCanonical := obj[canonical]
		if !hasCanonical {
			obj[canonical] = val
		}
		if !warned[warnKey] {
			*diagnostics = append(*diagnostics, DeprecatedKeyDiagnostic{
				Section:       path,
				DeprecatedKey: legacy,
				CanonicalKey:  canonical,
				Ignored:       hasCanonical,
			})
			warned[warnKey] = true
		}
		delete(obj, legacy)
		changed = true
	}
	return changed
}
