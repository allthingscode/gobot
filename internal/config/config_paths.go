package config

import (
	"os"
	"path/filepath"
)

// ProjectRoot returns the project source directory.
func (c *Config) ProjectRoot() string {
	return c.projectRoot
}

// SetProjectRoot sets the project source directory.
func (c *Config) SetProjectRoot(root string) {
	c.projectRoot = root
}

// TemplatesPath returns the custom directory for email templates, if configured.
func (c *Config) TemplatesPath() string {
	return c.Runtime.TemplatesPath
}

// StorageRoot returns the configured storage root.
// Priority:
// 1. config.json (runtime.storage_root)
// 2. GOBOT_STORAGE environment variable (explicit override; existing installs unchanged)
// 3. $GOBOT_HOME/data (derived default, so a single GOBOT_HOME is the only path to set)
// 4. ~/gobot_data (portable default when neither GOBOT_STORAGE nor GOBOT_HOME is set).
//
// An install that sets GOBOT_HOME but not GOBOT_STORAGE resolves data under $GOBOT_HOME/data; set
// GOBOT_STORAGE explicitly to pin a separate location. GOBOT_STORAGE-set installs never relocate.
func (c *Config) StorageRoot() string {
	if c.Runtime.StorageRoot != "" {
		return c.Runtime.StorageRoot
	}
	if envRoot := os.Getenv("GOBOT_STORAGE"); envRoot != "" {
		return envRoot
	}
	if gobotHome := os.Getenv("GOBOT_HOME"); gobotHome != "" {
		return filepath.Join(gobotHome, "data")
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return "gobot_storage" // last resort fallback to current dir
	}
	return filepath.Join(home, "gobot_data")
}

// SecretsRoot returns the path to the secrets directory under StorageRoot.
func (c *Config) SecretsRoot() string {
	return filepath.Join(c.StorageRoot(), "secrets")
}

// LogsRoot returns the path to the logs directory under StorageRoot.
func (c *Config) LogsRoot() string {
	return filepath.Join(c.StorageRoot(), "logs")
}

// LogPath returns the path to a specific log file under LogsRoot.
func (c *Config) LogPath(filename string) string {
	return filepath.Join(c.LogsRoot(), filename)
}

// WorkspacePath returns the path to a resource under {StorageRoot}/workspace/.
// If MultiUserEnabled is true and userID is non-empty, the path is scoped to
// {StorageRoot}/workspace/users/{userID}/.
// Subpath elements are joined after the workspace directory.
func (c *Config) WorkspacePath(userID string, subpath ...string) string {
	base := filepath.Join(c.StorageRoot(), "workspace")
	if c.MultiUserEnabled() && userID != "" {
		base = filepath.Join(base, "users", userID)
	}
	parts := append([]string{base}, subpath...)
	return filepath.Join(parts...)
}

// PolicyFilePath returns the configured tool policy file path.
func (c *Config) PolicyFilePath() string {
	return c.Runtime.PolicyFilePath
}

// DefaultConfigPath returns ~/.gobot/config.json.
func DefaultConfigPath() string {
	if h := os.Getenv("GOBOT_HOME"); h != "" {
		return filepath.Join(h, ".gobot", "config.json")
	}
	home, _ := os.UserHomeDir()
	return filepath.Join(home, ".gobot", "config.json")
}
