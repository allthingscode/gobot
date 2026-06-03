// Package secrets manages encrypted key-value pairs.
// On Windows, DPAPI (CryptProtectData) is used for user-scoped encryption.
// On Linux/macOS, AES-256-GCM is used with a per-user key stored at
// ~/.config/gobot/encryption.key (overridable via GOBOT_ENCRYPTION_KEY_FILE).
package secrets

import (
	"encoding/base64"
	"encoding/json"
	"fmt"
	"os"
	"os/user"
	"path/filepath"
	"runtime"
	"sort"
	"time"
)

// #nosec G101 - This is a filename, not a secret.
const secretsFileName = "dpapi_secrets.json"

// SecretsStore persists DPAPI-encrypted secrets in a JSON file at
// {storageRoot}/workspace/dpapi_secrets.json.
//
// revive:disable:exported
type SecretsStore struct {
	path string
}

// NewSecretsStore returns a SecretsStore backed by the given storage root.
// It does not open any file; the file is read/written on each operation.
func NewSecretsStore(storageRoot string) *SecretsStore {
	return &SecretsStore{
		path: filepath.Join(storageRoot, "workspace", secretsFileName),
	}
}

// Set encrypts value using DPAPI and stores it under key.
func (s *SecretsStore) Set(key, value string) error {
	encrypted, err := protect([]byte(value))
	if err != nil {
		return fmt.Errorf("secrets set %q: %w", key, err)
	}
	m, err := s.load()
	if err != nil {
		return fmt.Errorf("load secrets: %w", err)
	}
	m[key] = base64.StdEncoding.EncodeToString(encrypted)
	return s.save(m)
}

// Get decrypts and returns the value for key.
// Returns ("", nil) if the key does not exist.
func (s *SecretsStore) Get(key string) (string, error) {
	m, err := s.load()
	if err != nil {
		return "", fmt.Errorf("load secrets: %w", err)
	}
	encoded, ok := m[key]
	if !ok {
		return "", nil
	}
	encrypted, err := base64.StdEncoding.DecodeString(encoded)
	if err != nil {
		return "", fmt.Errorf("decode secret %q: %w", key, err)
	}
	decrypted, err := unprotect(encrypted)
	if err != nil {
		return "", fmt.Errorf("unprotect secret %q: %w", key, err)
	}
	return string(decrypted), nil
}

// List returns a sorted list of all keys in the store.
func (s *SecretsStore) List() ([]string, error) {
	m, err := s.load()
	if err != nil {
		return nil, fmt.Errorf("load secrets: %w", err)
	}
	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	return keys, nil
}

// Delete removes a key from the store. It is not an error if the key does not exist.
func (s *SecretsStore) Delete(key string) error {
	m, err := s.load()
	if err != nil {
		return fmt.Errorf("load secrets: %w", err)
	}
	delete(m, key)
	return s.save(m)
}

// roundtripKeyPrefix is the key prefix used by the secrets pre-flight round-trip
// test. Keys are suffixed with a timestamp to avoid collisions.
const roundtripKeyPrefix = "preflight.test"

// roundtripValue is the sentinel value written and read back during the
// pre-flight round-trip test.
const roundtripValue = "gobot-secrets-preflight"

// Roundtripper is the minimal subset of *SecretsStore needed to perform a
// Set→Get→Delete liveness check. It exists so callers (and tests) can supply a
// fake store without touching real DPAPI/AES storage.
type Roundtripper interface {
	Set(key, value string) error
	Get(key string) (string, error)
	Delete(key string) error
}

// CurrentUsername returns the current OS user name, or "unknown-user" if it
// cannot be determined.
func CurrentUsername() string {
	u, err := user.Current()
	if err != nil || u == nil || u.Username == "" {
		return "unknown-user"
	}
	return u.Username
}

// RoundtripTest performs a Set→Get→Delete liveness check against store using a
// unique, self-cleaning key. It verifies that a freshly written secret can be
// read back unchanged — proving the encryption store (DPAPI on Windows,
// AES-256 on Linux/macOS) is usable by the current user account.
//
// On failure it returns an error identifying the current user and OS plus the
// failure reason, matching the messages historically emitted by
// `gobot secrets test`. It returns nil on success.
func RoundtripTest(store Roundtripper) error {
	username := CurrentUsername()
	testKey := fmt.Sprintf("%s.%d", roundtripKeyPrefix, time.Now().UTC().UnixNano())

	// Best-effort pre-clean in case a prior run left the key behind.
	_ = store.Delete(testKey)

	if err := store.Set(testKey, roundtripValue); err != nil {
		return fmt.Errorf("secrets pre-flight failed for user %q on %s: write failed: %w", username, runtime.GOOS, err)
	}
	defer func() { _ = store.Delete(testKey) }()

	got, err := store.Get(testKey)
	if err != nil {
		return fmt.Errorf("secrets pre-flight failed for user %q on %s: read failed: %w. On Windows, verify Task Scheduler runs under the same account used for gobot authorize/reauth", username, runtime.GOOS, err)
	}
	if got != roundtripValue {
		return fmt.Errorf("secrets pre-flight failed for user %q on %s: readback mismatch (got %q). On Windows, verify Task Scheduler runs under the same account used for gobot authorize/reauth", username, runtime.GOOS, got)
	}
	return nil
}

// load reads the JSON file. Returns an empty map if the file does not exist.
func (s *SecretsStore) load() (map[string]string, error) {
	data, err := os.ReadFile(s.path)
	if os.IsNotExist(err) {
		return map[string]string{}, nil
	}
	if err != nil {
		return nil, fmt.Errorf("secrets: read file: %w", err)
	}
	var m map[string]string
	if err := json.Unmarshal(data, &m); err != nil {
		return nil, fmt.Errorf("secrets: parse file: %w", err)
	}
	return m, nil
}

// save writes the map to the JSON file, creating parent dirs as needed.
func (s *SecretsStore) save(m map[string]string) error {
	if err := os.MkdirAll(filepath.Dir(s.path), 0o755); err != nil {
		return fmt.Errorf("secrets: create dir: %w", err)
	}
	data, err := json.MarshalIndent(m, "", "  ")
	if err != nil {
		return fmt.Errorf("secrets: marshal: %w", err)
	}
	if err := os.WriteFile(s.path, data, 0o600); err != nil {
		return fmt.Errorf("secrets: write file: %w", err)
	}
	return nil
}
