package config

import (
	"encoding/json"
	"log/slog"
)

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

// normalizeLegacyKeys rewrites deprecated snake_case keys to their canonical camelCase
// form (see legacyKeyRenames) so a config written with the old names still loads. It
// returns the input unchanged when the payload is not a JSON object (the strict decoder
// then reports the real error) or when no legacy key is present.
func normalizeLegacyKeys(data []byte) []byte {
	var root map[string]json.RawMessage
	if err := json.Unmarshal(data, &root); err != nil {
		return data
	}
	if !renameKeysAtPath(root, "", map[string]bool{}) {
		return data
	}
	out, err := json.Marshal(root)
	if err != nil {
		return data
	}
	return out
}

// renameKeysAtPath applies the rules registered for obj's own path, then descends only
// into child objects that (or whose ".*" map entries) have their own rules. Returns true
// if any key was renamed in the subtree.
func renameKeysAtPath(obj map[string]json.RawMessage, path string, warned map[string]bool) bool {
	changed := false
	if renames, ok := legacyKeyRenames[path]; ok {
		changed = applyRenames(obj, path, renames, warned)
	}
	for childKey, childRaw := range obj {
		if descendChild(obj, childKey, childRaw, childPathOf(path, childKey), warned) {
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
func normalizeChild(child map[string]json.RawMessage, childPath string, warned map[string]bool) bool {
	changed := false
	if _, ok := legacyKeyRenames[childPath]; ok && renameKeysAtPath(child, childPath, warned) {
		changed = true
	}
	if wildRenames, ok := legacyKeyRenames[childPath+".*"]; ok && renameMapEntries(child, childPath+".*", wildRenames, warned) {
		changed = true
	}
	return changed
}

// descendChild recurses into a single child object when a rule applies at childPath,
// re-marshaling it back into parent on change.
func descendChild(parent map[string]json.RawMessage, childKey string, childRaw json.RawMessage, childPath string, warned map[string]bool) bool {
	if !hasRuleForPath(childPath) {
		return false
	}
	var child map[string]json.RawMessage
	if err := json.Unmarshal(childRaw, &child); err != nil || child == nil {
		return false
	}
	if !normalizeChild(child, childPath, warned) {
		return false
	}
	if rm, err := json.Marshal(child); err == nil {
		parent[childKey] = rm
	}
	return true
}

// renameMapEntries applies renames to every value of a JSON object used as a map (e.g.
// each named circuit breaker), re-marshaling changed entries in place.
func renameMapEntries(m map[string]json.RawMessage, path string, renames map[string]string, warned map[string]bool) bool {
	changed := false
	for k, raw := range m {
		var inner map[string]json.RawMessage
		if err := json.Unmarshal(raw, &inner); err != nil || inner == nil {
			continue
		}
		if applyRenames(inner, path, renames, warned) {
			if rm, err := json.Marshal(inner); err == nil {
				m[k] = rm
				changed = true
			}
		}
	}
	return changed
}

// applyRenames moves each present legacy key to its canonical key within obj, logging
// exactly one WARN per legacy key per load. When both keys are present the canonical
// value wins and the legacy key is dropped (with a warning). Returns true if modified.
func applyRenames(obj map[string]json.RawMessage, path string, renames map[string]string, warned map[string]bool) bool {
	changed := false
	for legacy, canonical := range renames {
		val, present := obj[legacy]
		if !present {
			continue
		}
		warnKey := path + "/" + legacy
		if _, hasCanonical := obj[canonical]; hasCanonical {
			if !warned[warnKey] {
				slog.Warn("config: deprecated key ignored because the canonical key is also present; remove the deprecated key",
					"deprecated_key", legacy, "canonical_key", canonical, "section", path)
				warned[warnKey] = true
			}
		} else {
			obj[canonical] = val
			if !warned[warnKey] {
				slog.Warn("config: deprecated key in use; rename it to the canonical key",
					"deprecated_key", legacy, "canonical_key", canonical, "section", path)
				warned[warnKey] = true
			}
		}
		delete(obj, legacy)
		changed = true
	}
	return changed
}
