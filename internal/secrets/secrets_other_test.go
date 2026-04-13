//go:build !windows

//nolint:testpackage
package secrets

import (
	"bytes"
	"path/filepath"
	"testing"
)

// TestProtectUnprotect verifies AES-256-GCM round-trips correctly for various inputs.
func TestProtectUnprotect(t *testing.T) {
	// Not parallel — uses t.Setenv for key-file isolation.
	t.Setenv("GOBOT_ENCRYPTION_KEY_FILE", filepath.Join(t.TempDir(), "encryption.key"))

	tests := []struct {
		name  string
		input []byte
	}{
		{"empty", []byte{}},
		{"short", []byte("hello")},
		{"long", bytes.Repeat([]byte("abc"), 1000)},
		{"binary", []byte{0x00, 0xFF, 0xFE, 0x01}},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			ciphertext, err := protect(tc.input)
			if err != nil {
				t.Fatalf("protect: %v", err)
			}
			plaintext, err := unprotect(ciphertext)
			if err != nil {
				t.Fatalf("unprotect: %v", err)
			}
			if !bytes.Equal(plaintext, tc.input) {
				t.Errorf("round-trip mismatch: got %q, want %q", plaintext, tc.input)
			}
		})
	}
}

// TestProtect_NonceRandomness verifies that two protect calls on identical input
// produce distinct ciphertexts (random nonce per call).
func TestProtect_NonceRandomness(t *testing.T) {
	t.Setenv("GOBOT_ENCRYPTION_KEY_FILE", filepath.Join(t.TempDir(), "encryption.key"))

	input := []byte("same input for both calls")
	c1, err := protect(input)
	if err != nil {
		t.Fatalf("protect first: %v", err)
	}
	c2, err := protect(input)
	if err != nil {
		t.Fatalf("protect second: %v", err)
	}
	if bytes.Equal(c1, c2) {
		t.Error("two protect calls produced identical ciphertext; nonce randomness is broken")
	}
}

// TestUnprotect_CorruptCiphertext verifies that tampered ciphertext returns an error.
func TestUnprotect_CorruptCiphertext(t *testing.T) {
	t.Setenv("GOBOT_ENCRYPTION_KEY_FILE", filepath.Join(t.TempDir(), "encryption.key"))

	tests := []struct {
		name       string
		ciphertext []byte
	}{
		{"too_short", []byte("short")},
		{"garbage", bytes.Repeat([]byte{0xAA}, 30)},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			_, err := unprotect(tc.ciphertext)
			if err == nil {
				t.Error("expected error for corrupt ciphertext, got nil")
			}
		})
	}
}

// TestKeyPersistence verifies that a key generated on the first call is reused
// on subsequent calls (the same key file is loaded).
func TestKeyPersistence(t *testing.T) {
	t.Setenv("GOBOT_ENCRYPTION_KEY_FILE", filepath.Join(t.TempDir(), "encryption.key"))

	input := []byte("persistent value")
	ciphertext, err := protect(input)
	if err != nil {
		t.Fatalf("protect: %v", err)
	}
	// Decrypt using the persisted key — must succeed.
	plaintext, err := unprotect(ciphertext)
	if err != nil {
		t.Fatalf("unprotect with persisted key: %v", err)
	}
	if !bytes.Equal(plaintext, input) {
		t.Errorf("got %q, want %q", plaintext, input)
	}
}

// TestSecretsStore_SetAndGet_NonWindows verifies the full store round-trip on non-Windows.
func TestSecretsStore_SetAndGet_NonWindows(t *testing.T) {
	t.Setenv("GOBOT_ENCRYPTION_KEY_FILE", filepath.Join(t.TempDir(), "encryption.key"))

	store := NewSecretsStore(t.TempDir())
	if err := store.Set("gemini_api_key", "my-secret-key-123"); err != nil {
		t.Fatalf("Set: %v", err)
	}
	got, err := store.Get("gemini_api_key")
	if err != nil {
		t.Fatalf("Get: %v", err)
	}
	if got != "my-secret-key-123" {
		t.Errorf("Get = %q, want %q", got, "my-secret-key-123")
	}
}

// TestSecretsStore_GetMissingKey_NonWindows verifies Get returns "" with no error for unknown keys.
func TestSecretsStore_GetMissingKey_NonWindows(t *testing.T) {
	t.Setenv("GOBOT_ENCRYPTION_KEY_FILE", filepath.Join(t.TempDir(), "encryption.key"))

	store := NewSecretsStore(t.TempDir())
	got, err := store.Get("nonexistent")
	if err != nil {
		t.Fatalf("Get missing key: %v", err)
	}
	if got != "" {
		t.Errorf("Get missing key = %q, want empty string", got)
	}
}

// TestSecretsStore_List_NonWindows verifies List returns keys in sorted order.
func TestSecretsStore_List_NonWindows(t *testing.T) {
	t.Setenv("GOBOT_ENCRYPTION_KEY_FILE", filepath.Join(t.TempDir(), "encryption.key"))

	store := NewSecretsStore(t.TempDir())
	for _, kv := range []struct{ k, v string }{
		{"telegram_token", "token-abc"},
		{"gemini_api_key", "key-xyz"},
		{"other_secret", "val"},
	} {
		if err := store.Set(kv.k, kv.v); err != nil {
			t.Fatalf("Set %q: %v", kv.k, err)
		}
	}

	keys, err := store.List()
	if err != nil {
		t.Fatalf("List: %v", err)
	}
	if len(keys) != 3 {
		t.Fatalf("len(keys) = %d, want 3", len(keys))
	}
	want := []string{"gemini_api_key", "other_secret", "telegram_token"}
	for i, k := range keys {
		if k != want[i] {
			t.Errorf("keys[%d] = %q, want %q", i, k, want[i])
		}
	}
}

// TestSecretsStore_Delete_NonWindows verifies deleted keys are gone from the store.
func TestSecretsStore_Delete_NonWindows(t *testing.T) {
	t.Setenv("GOBOT_ENCRYPTION_KEY_FILE", filepath.Join(t.TempDir(), "encryption.key"))

	store := NewSecretsStore(t.TempDir())
	if err := store.Set("key1", "value1"); err != nil {
		t.Fatalf("Set: %v", err)
	}
	if err := store.Delete("key1"); err != nil {
		t.Fatalf("Delete: %v", err)
	}
	got, err := store.Get("key1")
	if err != nil {
		t.Fatalf("Get after delete: %v", err)
	}
	if got != "" {
		t.Errorf("Get after delete = %q, want empty string", got)
	}
}

// TestSecretsStore_PersistAcrossInstances_NonWindows verifies that a second store
// instance reading the same directory decrypts values written by the first.
func TestSecretsStore_PersistAcrossInstances_NonWindows(t *testing.T) {
	t.Setenv("GOBOT_ENCRYPTION_KEY_FILE", filepath.Join(t.TempDir(), "encryption.key"))

	root := t.TempDir()
	s1 := NewSecretsStore(root)
	if err := s1.Set("key", "persisted-value"); err != nil {
		t.Fatalf("Set: %v", err)
	}
	s2 := NewSecretsStore(root)
	got, err := s2.Get("key")
	if err != nil {
		t.Fatalf("Get from new instance: %v", err)
	}
	if got != "persisted-value" {
		t.Errorf("Get = %q, want %q", got, "persisted-value")
	}
}
