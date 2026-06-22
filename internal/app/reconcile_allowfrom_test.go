package app_test

import (
	"context"
	"testing"
	"time"

	"github.com/allthingscode/gobot/internal/app"
	"github.com/allthingscode/gobot/internal/config"
	agentctx "github.com/allthingscode/gobot/internal/context"
)

// stubCheckpointStore satisfies agent.CheckpointStore without being a
// *CheckpointManager, to exercise the reconcile no-op branch.
type stubCheckpointStore struct{}

func (stubCheckpointStore) LoadLatest(context.Context, string) (*agentctx.ThreadSnapshot, error) {
	return nil, nil
}

func (stubCheckpointStore) SaveSnapshot(context.Context, string, int, []agentctx.StrategicMessage) (bool, error) {
	return false, nil
}

func (stubCheckpointStore) CreateThread(context.Context, string, string, map[string]any) error {
	return nil
}

func (stubCheckpointStore) UpdateSessionTokens(context.Context, string, int, *time.Time) error {
	return nil
}

func (stubCheckpointStore) GetSessionTokens(context.Context, string) (int, *time.Time, error) {
	return 0, nil, nil
}

func newCheckpointManagerForTest(t *testing.T) *agentctx.CheckpointManager {
	t.Helper()
	cm, err := agentctx.GetCheckpointManager(t.TempDir())
	if err != nil {
		t.Skipf("cannot create checkpoint manager: %v", err)
	}
	t.Cleanup(func() { _ = cm.DB().Close() })
	return cm
}

func cfgWithAllowFrom(ids ...string) *config.Config {
	cfg := &config.Config{}
	cfg.Channels.Telegram.AllowFrom = ids
	return cfg
}

func TestReconcileAuthorizedFromAllowFrom_AuthorizesWhitelisted(t *testing.T) {
	t.Parallel()
	cm := newCheckpointManagerForTest(t)
	store, err := agentctx.NewPairingStore(cm.DB())
	if err != nil {
		t.Fatalf("pairing store: %v", err)
	}

	n := app.ReconcileAuthorizedFromAllowFrom(cfgWithAllowFrom("111", "222"), cm)
	if n != 2 {
		t.Fatalf("reconciled count: got %d, want 2", n)
	}
	for _, id := range []int64{111, 222} {
		authorized, aerr := store.IsAuthorized(id)
		if aerr != nil {
			t.Fatalf("IsAuthorized(%d): %v", id, aerr)
		}
		if !authorized {
			t.Errorf("chat ID %d should be authorized after reconcile", id)
		}
	}
}

func TestReconcileAuthorizedFromAllowFrom_Idempotent(t *testing.T) {
	t.Parallel()
	cm := newCheckpointManagerForTest(t)
	cfg := cfgWithAllowFrom("333")

	if n := app.ReconcileAuthorizedFromAllowFrom(cfg, cm); n != 1 {
		t.Fatalf("first run reconciled: got %d, want 1", n)
	}
	if n := app.ReconcileAuthorizedFromAllowFrom(cfg, cm); n != 0 {
		t.Errorf("second run should be a no-op: got %d newly authorized, want 0", n)
	}
}

func TestReconcileAuthorizedFromAllowFrom_SkipsAlreadyAuthorized(t *testing.T) {
	t.Parallel()
	cm := newCheckpointManagerForTest(t)
	store, err := agentctx.NewPairingStore(cm.DB())
	if err != nil {
		t.Fatalf("pairing store: %v", err)
	}
	if err := store.AuthorizeByChatID(444, "operator"); err != nil {
		t.Fatalf("seed authorize: %v", err)
	}

	// 444 already authorized, 555 is new -> only 555 counts.
	if n := app.ReconcileAuthorizedFromAllowFrom(cfgWithAllowFrom("444", "555"), cm); n != 1 {
		t.Errorf("reconciled count: got %d, want 1 (only the new ID)", n)
	}
}

func TestReconcileAuthorizedFromAllowFrom_IgnoresNonNumeric(t *testing.T) {
	t.Parallel()
	cm := newCheckpointManagerForTest(t)
	if n := app.ReconcileAuthorizedFromAllowFrom(cfgWithAllowFrom("not-a-number", "666"), cm); n != 1 {
		t.Errorf("non-numeric entry should be ignored: got %d, want 1", n)
	}
}

func TestReconcileAuthorizedFromAllowFrom_NilInputs(t *testing.T) {
	t.Parallel()
	cm := newCheckpointManagerForTest(t)
	if n := app.ReconcileAuthorizedFromAllowFrom(nil, nil); n != 0 {
		t.Errorf("nil cfg/store: got %d, want 0", n)
	}
	if n := app.ReconcileAuthorizedFromAllowFrom(cfgWithAllowFrom("777"), nil); n != 0 {
		t.Errorf("nil store: got %d, want 0", n)
	}
	if n := app.ReconcileAuthorizedFromAllowFrom(nil, cm); n != 0 {
		t.Errorf("nil cfg: got %d, want 0", n)
	}
}

func TestReconcileAuthorizedFromAllowFrom_NonCheckpointStore(t *testing.T) {
	t.Parallel()
	// A store that is not a *CheckpointManager is a no-op.
	if n := app.ReconcileAuthorizedFromAllowFrom(cfgWithAllowFrom("888"), stubCheckpointStore{}); n != 0 {
		t.Errorf("non-CheckpointManager store should be a no-op: got %d, want 0", n)
	}
}

func TestReconcileAuthorizedFromAllowFrom_UnusableDB(t *testing.T) {
	t.Parallel()
	cm, err := agentctx.GetCheckpointManager(t.TempDir())
	if err != nil {
		t.Skipf("cannot create checkpoint manager: %v", err)
	}
	// Closing the DB makes schema init / queries fail; reconcile must warn and
	// return 0 rather than panic.
	_ = cm.DB().Close()
	if n := app.ReconcileAuthorizedFromAllowFrom(cfgWithAllowFrom("999"), cm); n != 0 {
		t.Errorf("unusable DB should yield 0 reconciled, got %d", n)
	}
}
