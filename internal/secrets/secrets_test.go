//go:build windows

package secrets

import (
	"testing"
)

// TestSecretsStore_SetAndGet verifies that a stored value round-trips through DPAPI.
func TestSecretsStore_SetAndGet(t *testing.T) {
	t.Parallel()
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

// TestSecretsStore_GetMissingKey verifies that Get returns "" with no error for unknown keys.
func TestSecretsStore_GetMissingKey(t *testing.T) {
	t.Parallel()
	store := NewSecretsStore(t.TempDir())
	got, err := store.Get("nonexistent")
	if err != nil {
		t.Fatalf("Get missing key: %v", err)
	}
	if got != "" {
		t.Errorf("Get missing key = %q, want empty string", got)
	}
}

// TestSecretsStore_List verifies that List returns keys in sorted order.
func TestSecretsStore_List(t *testing.T) {
	t.Parallel()
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

// TestSecretsStore_Delete verifies that a deleted key is gone from the store.
func TestSecretsStore_Delete(t *testing.T) {
	t.Parallel()
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

// TestSecretsStore_PersistAcrossInstances verifies the store is durable — a new
// SecretsStore pointed at the same dir reads back what a prior instance wrote.
func TestSecretsStore_PersistAcrossInstances(t *testing.T) {
	t.Parallel()
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
