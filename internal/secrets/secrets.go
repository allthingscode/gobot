// Package secrets manages encrypted key-value pairs using Windows DPAPI.
// On non-Windows platforms the protect/unprotect functions return an error.
package secrets

import (
	"encoding/base64"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sort"
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
		return err
	}
	m[key] = base64.StdEncoding.EncodeToString(encrypted)
	return s.save(m)
}

// Get decrypts and returns the value for key.
// Returns ("", nil) if the key does not exist.
func (s *SecretsStore) Get(key string) (string, error) {
	m, err := s.load()
	if err != nil {
		return "", err
	}
	encoded, ok := m[key]
	if !ok {
		return "", nil
	}
	ciphertext, err := base64.StdEncoding.DecodeString(encoded)
	if err != nil {
		return "", fmt.Errorf("secrets get %q: base64 decode: %w", key, err)
	}
	plaintext, err := unprotect(ciphertext)
	if err != nil {
		return "", fmt.Errorf("secrets get %q: %w", key, err)
	}
	return string(plaintext), nil
}

// List returns all stored key names in sorted order.
func (s *SecretsStore) List() ([]string, error) {
	m, err := s.load()
	if err != nil {
		return nil, err
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
		return err
	}
	delete(m, key)
	return s.save(m)
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
	return os.WriteFile(s.path, data, 0o600)
}
