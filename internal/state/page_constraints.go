package state

import (
	"fmt"
	"path/filepath"
	"strings"
	"time"
)

// PageConstraintSignal captures the latest extraction constraint classification for a session.
type PageConstraintSignal struct {
	SessionKey         string    `json:"session_key"`
	Classification     string    `json:"classification"`
	LastBlockingSignal string    `json:"last_blocking_signal"`
	ObservedAt         time.Time `json:"observed_at"`
}

// SavePageConstraintSignal persists the latest page-constraint classification for a session.
func SavePageConstraintSignal(storageRoot, sessionKey, classification, lastSignal string) error {
	if strings.TrimSpace(storageRoot) == "" {
		return fmt.Errorf("save page constraint: storage root is required")
	}
	if strings.TrimSpace(sessionKey) == "" {
		return fmt.Errorf("save page constraint: session key is required")
	}

	payload := PageConstraintSignal{
		SessionKey:         sessionKey,
		Classification:     strings.TrimSpace(classification),
		LastBlockingSignal: strings.TrimSpace(lastSignal),
		ObservedAt:         time.Now().UTC(),
	}

	safeSessionKey := strings.NewReplacer("/", "_", "\\", "_", ":", "_", " ", "_").Replace(sessionKey)
	path := filepath.Join(storageRoot, "state", "page_constraints", safeSessionKey+".json")
	if err := WriteFileJSON(path, payload, 0o600); err != nil {
		return fmt.Errorf("save page constraint: %w", err)
	}
	return nil
}
