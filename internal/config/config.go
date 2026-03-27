// Package config loads the nanobot config.json with BOM stripping and struct validation.
package config

import (
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
)

// bomPrefix is the UTF-8 byte order mark written by some Windows editors.
var bomPrefix = []byte{0xEF, 0xBB, 0xBF}

// Config mirrors the relevant fields of ~/.nanobot/config.json.
type Config struct {
	Agents    AgentsConfig    `json:"agents"`
	Providers ProvidersConfig `json:"providers"`
	Strategic StrategicConfig `json:"strategic_edition"`
}

type AgentsConfig struct {
	Defaults  AgentDefaults            `json:"defaults"`
	Specialists map[string]SpecialistConfig `json:"specialists"`
}

type AgentDefaults struct {
	Model     string `json:"model"`
	Workspace string `json:"workspace"`
}

type SpecialistConfig struct {
	Model string `json:"model"`
}

type ProvidersConfig struct {
	Gemini GeminiConfig `json:"gemini"`
}

type GeminiConfig struct {
	APIKey string `json:"apiKey"`
}

type StrategicConfig struct {
	UserEmail    string `json:"user_email"`
	StorageRoot  string `json:"storage_root"`
	Mandate      string `json:"mandate"`
	UseGoBridge  bool   `json:"use_go_bridge"`
	GoBridgePort int    `json:"go_bridge_port"`
}

// StorageRoot returns the configured storage root, defaulting to D:/Nanobot_Storage.
func (c *Config) StorageRoot() string {
	if c.Strategic.StorageRoot != "" {
		return c.Strategic.StorageRoot
	}
	return `D:\Nanobot_Storage`
}

// GeminiAPIKey returns the Gemini API key from config.
func (c *Config) GeminiAPIKey() string {
	return c.Providers.Gemini.APIKey
}

// DefaultConfigPath returns ~/.nanobot/config.json.
func DefaultConfigPath() string {
	home, _ := os.UserHomeDir()
	return filepath.Join(home, ".nanobot", "config.json")
}

// Load reads and parses the config from the default path.
func Load() (*Config, error) {
	return LoadFrom(DefaultConfigPath())
}

// LoadFrom reads and parses a config file, stripping a leading UTF-8 BOM if present.
func LoadFrom(path string) (*Config, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, fmt.Errorf("open config %s: %w", path, err)
	}
	defer f.Close()

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
		data[0] == bomPrefix[0] &&
		data[1] == bomPrefix[1] &&
		data[2] == bomPrefix[2] {
		data = data[3:]
	}

	var cfg Config
	if err := json.Unmarshal(data, &cfg); err != nil {
		return nil, fmt.Errorf("parse config: %w", err)
	}
	return &cfg, nil
}
