//go:build !windows

package secrets

import (
	"crypto/aes"
	"crypto/cipher"
	"crypto/rand"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
)

// protect encrypts plaintext using AES-256-GCM with a per-user key stored at
// the path returned by keyFilePath(). The returned bytes prepend the 12-byte
// nonce so unprotect can reconstruct the GCM state.
func protect(plaintext []byte) ([]byte, error) {
	key, err := loadOrCreateKey()
	if err != nil {
		return nil, fmt.Errorf("protect: %w", err)
	}

	block, err := aes.NewCipher(key)
	if err != nil {
		return nil, fmt.Errorf("protect: new cipher: %w", err)
	}
	gcm, err := cipher.NewGCM(block)
	if err != nil {
		return nil, fmt.Errorf("protect: new gcm: %w", err)
	}

	nonce := make([]byte, gcm.NonceSize())
	if _, err := io.ReadFull(rand.Reader, nonce); err != nil {
		return nil, fmt.Errorf("protect: generate nonce: %w", err)
	}
	// Seal appends ciphertext+tag to nonce slice, so nonce is embedded.
	return gcm.Seal(nonce, nonce, plaintext, nil), nil
}

// unprotect decrypts AES-256-GCM ciphertext produced by protect.
func unprotect(ciphertext []byte) ([]byte, error) {
	key, err := loadOrCreateKey()
	if err != nil {
		return nil, fmt.Errorf("unprotect: %w", err)
	}

	block, err := aes.NewCipher(key)
	if err != nil {
		return nil, fmt.Errorf("unprotect: new cipher: %w", err)
	}
	gcm, err := cipher.NewGCM(block)
	if err != nil {
		return nil, fmt.Errorf("unprotect: new gcm: %w", err)
	}

	nonceSize := gcm.NonceSize()
	minLen := nonceSize + gcm.Overhead()
	if len(ciphertext) < minLen {
		return nil, fmt.Errorf("unprotect: ciphertext too short (%d bytes, need ≥%d)", len(ciphertext), minLen)
	}

	plaintext, err := gcm.Open(nil, ciphertext[:nonceSize], ciphertext[nonceSize:], nil)
	if err != nil {
		return nil, fmt.Errorf("unprotect: decrypt: %w", err)
	}
	return plaintext, nil
}

// keyFilePath returns the path to the 32-byte AES-256 encryption key file.
// The GOBOT_ENCRYPTION_KEY_FILE environment variable overrides the default
// (~/.config/gobot/encryption.key on Linux; ~/Library/Application Support on macOS)
// so that tests and CI can use an isolated temporary path.
func keyFilePath() string {
	if v := os.Getenv("GOBOT_ENCRYPTION_KEY_FILE"); v != "" {
		return v
	}
	dir, err := os.UserConfigDir()
	if err != nil {
		home, _ := os.UserHomeDir()
		dir = filepath.Join(home, ".config")
	}
	return filepath.Join(dir, "gobot", "encryption.key")
}

// loadOrCreateKey reads the 32-byte AES-256 key from disk, generating and
// persisting a fresh key if the file does not yet exist.
func loadOrCreateKey() ([]byte, error) {
	path := keyFilePath()
	data, err := os.ReadFile(path)
	if err == nil {
		if len(data) != 32 {
			return nil, fmt.Errorf("load key: unexpected key length %d (want 32)", len(data))
		}
		return data, nil
	}
	if !errors.Is(err, os.ErrNotExist) {
		return nil, fmt.Errorf("load key: read %s: %w", path, err)
	}

	// Generate a fresh 32-byte (256-bit) random key.
	key := make([]byte, 32)
	if _, err := io.ReadFull(rand.Reader, key); err != nil {
		return nil, fmt.Errorf("load key: generate: %w", err)
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return nil, fmt.Errorf("load key: mkdir: %w", err)
	}
	if err := os.WriteFile(path, key, 0o600); err != nil {
		return nil, fmt.Errorf("load key: write %s: %w", path, err)
	}
	return key, nil
}
