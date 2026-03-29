package audit

import (
	"testing"
)

// newTestLedger opens a fresh AuditLedger backed by a temp dir.
func newTestLedger(t *testing.T) *AuditLedger {
	t.Helper()
	l, err := NewAuditLedger(t.TempDir())
	if err != nil {
		t.Fatalf("NewAuditLedger: %v", err)
	}
	t.Cleanup(func() { l.Close() })
	return l
}

// TestAuditLedger_AppendAndGetAll verifies basic append and retrieval.
func TestAuditLedger_AppendAndGetAll(t *testing.T) {
	l := newTestLedger(t)

	entries := []AuditEntry{
		{SessionID: "s1", Actor: "agent", Action: "send_email", Result: "ok"},
		{SessionID: "s1", Actor: "user", Action: "message", Result: "hello"},
		{SessionID: "s2", Actor: "agent", Action: "list_tasks", Result: "3 tasks"},
	}
	for _, e := range entries {
		if err := l.Append(e); err != nil {
			t.Fatalf("Append: %v", err)
		}
	}

	records, err := l.GetAll()
	if err != nil {
		t.Fatalf("GetAll: %v", err)
	}
	if len(records) != 3 {
		t.Fatalf("len(records) = %d, want 3", len(records))
	}
	if records[0].Action != "send_email" {
		t.Errorf("records[0].Action = %q, want %q", records[0].Action, "send_email")
	}
	if records[2].SessionID != "s2" {
		t.Errorf("records[2].SessionID = %q, want %q", records[2].SessionID, "s2")
	}
}

// TestAuditLedger_HashChainValid verifies that Verify passes on an untampered ledger.
func TestAuditLedger_HashChainValid(t *testing.T) {
	l := newTestLedger(t)

	for i := 0; i < 5; i++ {
		if err := l.Append(AuditEntry{
			SessionID: "s1",
			Actor:     "agent",
			Action:    "tool_call",
			Result:    "done",
		}); err != nil {
			t.Fatalf("Append[%d]: %v", i, err)
		}
	}

	if err := l.Verify(); err != nil {
		t.Errorf("Verify on clean ledger: %v", err)
	}
}

// TestAuditLedger_EmptyLedger_Verify verifies that an empty ledger passes Verify.
func TestAuditLedger_EmptyLedger_Verify(t *testing.T) {
	l := newTestLedger(t)
	if err := l.Verify(); err != nil {
		t.Errorf("Verify on empty ledger: %v", err)
	}
}

// TestAuditLedger_PrevHashChained verifies that each record's PrevHash equals
// the previous record's Hash, forming a proper chain.
func TestAuditLedger_PrevHashChained(t *testing.T) {
	l := newTestLedger(t)

	for i := 0; i < 4; i++ {
		if err := l.Append(AuditEntry{
			SessionID: "s1",
			Actor:     "agent",
			Action:    "action",
			Result:    "result",
		}); err != nil {
			t.Fatalf("Append[%d]: %v", i, err)
		}
	}

	records, err := l.GetAll()
	if err != nil {
		t.Fatalf("GetAll: %v", err)
	}

	// First record must have empty PrevHash.
	if records[0].PrevHash != "" {
		t.Errorf("records[0].PrevHash = %q, want empty string", records[0].PrevHash)
	}
	// Each subsequent record's PrevHash must equal the prior record's Hash.
	for i := 1; i < len(records); i++ {
		if records[i].PrevHash != records[i-1].Hash {
			t.Errorf("records[%d].PrevHash = %q, want %q",
				i, records[i].PrevHash, records[i-1].Hash)
		}
	}
}

// TestAuditLedger_Verify_DetectsTampering verifies that modifying a stored
// result field without updating the hash causes Verify to return an error.
func TestAuditLedger_Verify_DetectsTampering(t *testing.T) {
	l := newTestLedger(t)

	if err := l.Append(AuditEntry{
		SessionID: "s1",
		Actor:     "agent",
		Action:    "send_email",
		Result:    "delivered",
	}); err != nil {
		t.Fatalf("Append: %v", err)
	}

	// Tamper: overwrite result without updating hash.
	if _, err := l.db.Exec(
		`UPDATE audit_log SET result = ? WHERE id = 1`,
		"not delivered",
	); err != nil {
		t.Fatalf("tamper: %v", err)
	}

	if err := l.Verify(); err == nil {
		t.Error("expected Verify to fail for tampered record, got nil")
	}
}
