package reminder

import (
	"context"
	"fmt"
	"log/slog"
	"time"
)

// Worker delivers stored text independently of models, tools and cron.
// Exactly one worker owns recovery for a running application.
type Worker struct {
	Store     *Store
	Authorize func(context.Context, Owner) (bool, error)
	Send      func(context.Context, Reminder) error
	Transient func(error) bool
	Logger    *slog.Logger
	now       func() time.Time // Optional deterministic clock for offline worker tests.
}

func (w *Worker) clock() time.Time {
	if w.now != nil {
		return w.now()
	}
	return time.Now()
}

// Run recovers interrupted sends and polls immediately, including overdue reminders.
// Cancellation interrupts the bounded send; the caller must join Run before closing Store.
func (w *Worker) Run(ctx context.Context) error {
	if err := w.Store.Recover(ctx, w.clock()); err != nil {
		return err
	}
	ticker := time.NewTicker(time.Second)
	defer ticker.Stop()
	for ctx.Err() == nil {
		worked, err := w.step(ctx, w.clock())
		if err != nil {
			if ctx.Err() != nil {
				return nil
			}
			return err
		}
		if worked {
			continue
		}
		select {
		case <-ctx.Done():
		case <-ticker.C:
		}
	}
	return nil
}

func (w *Worker) step(ctx context.Context, now time.Time) (bool, error) {
	if err := w.Store.Prune(ctx, now); err != nil {
		return false, err
	}
	r, found, err := w.Store.Claim(ctx, now)
	if err != nil || !found {
		return false, err
	}
	state, failure := w.deliver(ctx, r)
	// A cancelled send still needs a durable result. Keep this final write bounded.
	finishCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if err := w.Store.Finish(finishCtx, r, state, failure, w.clock()); err != nil {
		return true, fmt.Errorf("reminder record delivery outcome: %w", err)
	}
	logger := w.Logger
	if logger == nil {
		logger = slog.Default()
	}
	logger.Info("reminder delivery outcome", "id", r.ID, "state", state, "attempts", r.Attempts, "failure", failure)
	return true, nil
}

func (w *Worker) deliver(ctx context.Context, r Reminder) (state State, failure string) {
	sendCtx, cancel := context.WithTimeout(ctx, 20*time.Second)
	defer cancel()
	allowed, err := w.Authorize(sendCtx, r.Owner)
	if err != nil || !allowed {
		return Failed, "authorization_failed"
	}
	if err := sendCtx.Err(); err != nil {
		return w.deliveryFailure(r, err)
	}
	if err := w.Send(sendCtx, r); err != nil {
		return w.deliveryFailure(r, err)
	}
	return Delivered, ""
}

func (w *Worker) deliveryFailure(r Reminder, err error) (state State, failure string) {
	if r.Attempts >= 3 {
		return Failed, "attempts_exhausted"
	}
	if w.Transient != nil && w.Transient(err) {
		return Pending, "transient_delivery_failure"
	}
	return Failed, "delivery_failed"
}
