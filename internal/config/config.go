// Package config loads the gobot config.json with BOM stripping and struct validation.
package config

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"

	"github.com/allthingscode/gobot/internal/state"
)

// BOMPrefix is the UTF-8 byte order mark written by some Windows editors.
//
//nolint:gochecknoglobals // Immutable constant for BOM detection
var BOMPrefix = []byte{0xEF, 0xBB, 0xBF}

// Marshal returns the config as indented JSON with a leading UTF-8 BOM.
func (c *Config) Marshal() ([]byte, error) {
	data, err := json.MarshalIndent(c, "", "    ")
	if err != nil {
		return nil, fmt.Errorf("marshal config: %w", err)
	}

	finalData := make([]byte, 0, len(BOMPrefix)+len(data))
	finalData = append(finalData, BOMPrefix...)
	finalData = append(finalData, data...)
	return finalData, nil
}

// Save marshals the config to JSON and writes it to the specified path.
func (c *Config) Save(path string) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return fmt.Errorf("create config dir: %w", err)
	}
	data, err := c.Marshal()
	if err != nil {
		return err
	}
	if err := state.WriteFileAtomic(path, data, 0o600); err != nil {
		return fmt.Errorf("write config file: %w", err)
	}
	return nil
}

// Load reads and parses the config from the default path.
func Load() (*Config, error) {
	return LoadFrom(DefaultConfigPath())
}

// ExplainLoadError renders a config.Load/LoadFrom failure as an actionable
// problem/fix/path block (F-144 AC3). decode wraps malformed JSON and unknown
// fields as "config: invalid field or syntax: ..."; this turns that into a
// first-run-friendly message pointing at the exact file to edit. Returns "" when
// err is nil or is not a recognized config-parse failure.
func ExplainLoadError(err error) string {
	if err == nil {
		return ""
	}
	if !strings.Contains(err.Error(), "invalid field or syntax") {
		return ""
	}
	return fmt.Sprintf(
		"Problem: %s is not valid JSON, or contains an unknown field.\n"+
			"  Fix:   correct the JSON syntax / remove the unrecognized key (the parser names it above), then re-run.\n"+
			"  Path:  %s",
		DefaultConfigPath(), DefaultConfigPath())
}

// LoadFrom reads and parses a config file, stripping a leading UTF-8 BOM if present.
func LoadFrom(path string) (*Config, error) {
	f, err := os.Open(path)
	if err != nil {
		if os.IsNotExist(err) {
			return &Config{}, nil
		}
		return nil, fmt.Errorf("open config %s: %w", path, err)
	}
	defer func() { _ = f.Close() }()

	return decode(f)
}

// decode strips an optional BOM then JSON-decodes the reader into Config.
func decode(r io.Reader) (*Config, error) {
	data, err := io.ReadAll(r)
	if err != nil {
		return nil, fmt.Errorf("read config: %w", err)
	}

	// Strip UTF-8 BOM if present
	if len(data) >= 3 &&
		data[0] == BOMPrefix[0] &&
		data[1] == BOMPrefix[1] &&
		data[2] == BOMPrefix[2] {
		data = data[3:]
	}

	data = normalizeLegacyKeys(data)

	var cfg Config
	dec := json.NewDecoder(bytes.NewReader(data))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&cfg); err != nil {
		return nil, fmt.Errorf("config: invalid field or syntax: %w", err)
	}
	applyGatewayDefaults(&cfg)
	return &cfg, nil
}

// applyGatewayDefaults enforces local-safe binding defaults (F-139).
// An empty host binds to all interfaces (0.0.0.0); for a single-user local
// assistant we default to loopback. Explicit values (including 0.0.0.0) are
// preserved so an operator can still opt in to external binding.
func applyGatewayDefaults(cfg *Config) {
	if cfg.Gateway.Host == "" {
		cfg.Gateway.Host = "127.0.0.1"
	}
	if cfg.Gateway.WebAddr == "" && cfg.Gateway.DashboardEnabled {
		cfg.Gateway.WebAddr = "127.0.0.1:0"
	}
}
