//nolint:testpackage // validates SQLite row metadata directly
package context

import (
	"context"
	"database/sql"
	"testing"
)

//nolint:gocognit,cyclop // transition matrix verifies all preserved row fields
func TestHITLDeliveryLifecycle(t *testing.T) {
	t.Parallel()
	for _, decision := range []string{"approved", "rejected"} {
		for _, initial := range []string{"sending", "pending"} {
			t.Run(initial+"/"+decision, func(t *testing.T) {
				t.Parallel()
				m := newTestManager(t)
				ctx := context.Background()
				save := func(status string) {
					t.Helper()
					if err := m.SaveHITLApproval(ctx, "request", "telegram:123", "risk", map[string]any{"cmd": "ls"}, status); err != nil {
						t.Fatal(err)
					}
				}
				for _, status := range []string{initial, "sending", "pending", decision} {
					save(status)
					got, err := m.GetHITLApproval(ctx, "request")
					if err != nil || got != status {
						t.Fatalf("%s: %s %v", status, got, err)
					}
				}
				var decided, created string
				if err := m.db.QueryRowContext(ctx, `SELECT decided_at, created_at FROM hitl_approvals WHERE request_id = 'request'`).Scan(&decided, &created); err != nil {
					t.Fatal(err)
				}
				for _, status := range []string{"sending", "pending"} {
					if err := m.SaveHITLApproval(ctx, "request", "other", "other", nil, status); err != nil {
						t.Fatal(err)
					}
					var session, tool, args, got, newCreated string
					var newDecided sql.NullString
					err := m.db.QueryRowContext(ctx, `SELECT session_key,tool_name,args,status,created_at,decided_at FROM hitl_approvals WHERE request_id = 'request'`).Scan(&session, &tool, &args, &got, &newCreated, &newDecided)
					if err != nil {
						t.Fatal(err)
					}
					if got != decision || session != "telegram:123" || tool != "risk" || args != `{"cmd":"ls"}` || newCreated != created || !newDecided.Valid || newDecided.String != decided {
						t.Fatalf("row downgraded: %s %s %s %s %s %v", session, tool, args, got, newCreated, newDecided)
					}
				}
			})
		}
	}
}

func TestHITLLifecycleWriteErrors(t *testing.T) {
	t.Parallel()
	m := newTestManager(t)
	ctx := context.Background()
	if err := m.SaveHITLApproval(ctx, "bad-args", "", "", map[string]any{"invalid": make(chan bool)}, "sending"); err == nil {
		t.Fatal("expected marshal error")
	}
	if err := m.db.Close(); err != nil {
		t.Fatal(err)
	}
	if err := m.SaveHITLApproval(ctx, "closed", "", "", nil, "pending"); err == nil {
		t.Fatal("expected database error")
	}
}
