//nolint:testpackage // exercises private waiter lifecycle and timeout
package agent

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/allthingscode/gobot/internal/bot"
)

const (
	decisionOnError     = "decision-on-error"
	readErrorMode       = "read-error"
	unknownStatus       = "unknown"
	pendingWriteFailure = "pending-write-failure"
	unsupportedMode     = "unsupported"
)

type lifecycleAPI struct {
	bot.API
	send func(context.Context, [][]bot.Button) error
}

func (a *lifecycleAPI) Send(context.Context, bot.OutboundMessage) error { return nil }
func (a *lifecycleAPI) SendWithButtons(ctx context.Context, _ bot.OutboundMessage, buttons [][]bot.Button) error {
	return a.send(ctx, buttons)
}

type lifecycleStore struct {
	mu     sync.Mutex
	status string
	read   func() (string, error)
	write  func(string) error
}

func (s *lifecycleStore) GetHITLApproval(context.Context, string) (string, error) {
	if s.read != nil {
		return s.read()
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.status, nil
}
func (s *lifecycleStore) SaveHITLApproval(_ context.Context, _, _, _ string, _ map[string]any, status string) error {
	if s.write != nil {
		if err := s.write(status); err != nil {
			return err
		}
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if (status == hitlSending || status == hitlPending) && (s.status == hitlApproved || s.status == hitlRejected) {
		return nil
	}
	s.status = status
	return nil
}
func assertNoWaiter(t *testing.T, m *HITLManager) {
	t.Helper()
	m.mu.Lock()
	defer m.mu.Unlock()
	if len(m.pending) != 0 {
		t.Fatalf("leaked waiters: %d", len(m.pending))
	}
}
func callbackDecision(t *testing.T, m *HITLManager, data string) {
	t.Helper()
	if err := m.HandleCallback(context.Background(), bot.InboundCallback{ChatID: 123, Data: data}); err != nil {
		t.Fatal(err)
	}
}

//nolint:gocognit,cyclop // table matrices assert lifecycle outcomes and error paths together
func TestHITLEarlyDecision(t *testing.T) {
	t.Parallel()
	for _, stored := range []bool{false, true} {
		for _, reject := range []bool{false, true} {
			for _, failedWrite := range []string{"", hitlSending, "pending", hitlApproved, hitlRejected} {
				t.Run(fmt.Sprintf("store=%v/reject=%v/write=%s", stored, reject, failedWrite), func(t *testing.T) {
					t.Parallel()
					store := &lifecycleStore{write: func(status string) error {
						if status == failedWrite {
							return errors.New("write failed")
						}
						return nil
					}}
					var persistence HITLStore
					if stored {
						persistence = store
					}
					api := &lifecycleAPI{}
					m := NewHITLManager(api, persistence, []string{"risk"})
					api.send = func(_ context.Context, buttons [][]bot.Button) error {
						index := 0
						if reject {
							index = 1
						}
						// Two callbacks fill the buffer while delivery is still running.
						callbackDecision(t, m, buttons[0][index].Data)
						callbackDecision(t, m, buttons[0][index].Data)
						return nil
					}
					ctx, cancel := context.WithTimeout(context.Background(), time.Second)
					defer cancel()
					_, err := m.PreToolHook(ctx, "telegram:123", "risk", nil)
					if reject {
						if !errors.Is(err, ErrToolDenied) {
							t.Fatalf("want denial, got %v", err)
						}
					} else if err != nil {
						t.Fatal(err)
					}
					assertNoWaiter(t, m)
				})
			}
		}
	}
}

//nolint:gocognit,cyclop // table matrices assert lifecycle outcomes and error paths together
func TestHITLDeliveryRetry(t *testing.T) {
	t.Parallel()
	for _, mode := range []string{"memory", "stored", "restart", decisionOnError} {
		t.Run(mode, func(t *testing.T) {
			t.Parallel()
			store := &lifecycleStore{}
			var persistence HITLStore
			if mode != "memory" {
				persistence = store
			}
			api := &lifecycleAPI{}
			m := NewHITLManager(api, persistence, nil)
			transportErr := errors.New("transport failed")
			sends := 0
			api.send = func(_ context.Context, buttons [][]bot.Button) error {
				sends++
				if sends == 1 {
					if mode == decisionOnError {
						callbackDecision(t, m, buttons[0][0].Data)
					}
					return transportErr
				}
				callbackDecision(t, m, buttons[0][0].Data)
				return nil
			}
			approved, err := m.RequestApproval(context.Background(), "telegram:123", "risk", nil)
			if approved || !errors.Is(err, transportErr) {
				t.Fatalf("first: %v, %v", approved, err)
			}
			assertNoWaiter(t, m)
			if persistence != nil && mode != decisionOnError && store.status != hitlSending {
				t.Fatalf("status %s", store.status)
			}
			if mode == "restart" || mode == decisionOnError {
				m = NewHITLManager(api, persistence, nil)
			}
			ctx, cancel := context.WithTimeout(context.Background(), time.Second)
			defer cancel()
			approved, err = m.RequestApproval(ctx, "telegram:123", "risk", nil)
			if !approved || err != nil {
				t.Fatalf("retry: %v, %v", approved, err)
			}
			expected := 2
			if mode == decisionOnError {
				expected = 1
			}
			if sends != expected {
				t.Fatalf("sends %d", sends)
			}
			assertNoWaiter(t, m)
		})
	}
}

//nolint:gocognit,cyclop // table matrices assert lifecycle outcomes and error paths together
func TestHITLReconcileAndCleanup(t *testing.T) {
	t.Parallel()
	for _, mode := range []string{hitlApproved, hitlRejected, "pending-change", "pending-callback", readErrorMode, "reconcile-error", "cancel", "timeout", pendingWriteFailure, "sending-restart", "unknown-retry", "cron", unsupportedMode} {
		t.Run(mode, func(t *testing.T) {
			t.Parallel()
			store := &lifecycleStore{}
			api := &lifecycleAPI{}
			m := NewHITLManager(api, store, nil)
			reads, sends := 0, 0
			failure := errors.New("read failed")
			store.read = func() (string, error) {
				reads++
				switch mode {
				case hitlApproved, hitlRejected:
					return mode, nil
				case "pending-change":
					if reads == 1 {
						return hitlPending, nil
					}
					return hitlApproved, nil
				case "pending-callback":
					callbackDecision(t, m, "hitl:approve:"+m.createRequestID("telegram:123", "risk", nil))
					return hitlPending, nil
				case readErrorMode:
					return "", failure
				case "reconcile-error":
					if reads == 2 {
						return "", failure
					}
				case "sending-restart":
					return hitlSending, nil
				case "unknown-retry":
					return unknownStatus, nil
				}
				return "", nil
			}
			if mode == pendingWriteFailure {
				store.write = func(status string) error {
					if status == hitlPending {
						return errors.New("pending write failed")
					}
					return nil
				}
			}
			ctx, cancel := context.WithTimeout(context.Background(), time.Second)
			defer cancel()
			if mode == "timeout" {
				m.approvalTimeout = 0
			}
			api.send = func(_ context.Context, buttons [][]bot.Button) error {
				sends++
				switch mode {
				case "cancel", pendingWriteFailure:
					cancel()
				case "sending-restart", "unknown-retry":
					callbackDecision(t, m, buttons[0][0].Data)
				}
				return nil
			}
			session := "telegram:123"
			if mode == "cron" {
				session = "cron:job"
			}
			if mode == unsupportedMode {
				session = "cli:user"
			}
			approved, err := m.RequestApproval(ctx, session, "risk", nil)
			assertLifecycleOutcome(t, mode, approved, err, failure)
			if strings.HasPrefix(mode, "pending-") && mode != pendingWriteFailure || mode == hitlApproved || mode == hitlRejected || mode == "cron" || mode == unsupportedMode || mode == readErrorMode {
				if sends != 0 {
					t.Fatalf("unexpected send %d", sends)
				}
			}
			assertNoWaiter(t, m)
			ch, err := m.registerWaiter(m.createRequestID(session, "risk", nil))
			if err != nil {
				t.Fatal(err)
			}
			m.releaseWaiter(m.createRequestID(session, "risk", nil), ch)
		})
	}
}

//nolint:gocognit,cyclop // table matrices assert lifecycle outcomes and error paths together
func TestHITLConcurrentOwnership(t *testing.T) {
	t.Parallel()
	entered, release := make(chan struct{}), make(chan struct{})
	api := &lifecycleAPI{}
	m := NewHITLManager(api, nil, nil)
	api.send = func(_ context.Context, buttons [][]bot.Button) error {
		close(entered)
		<-release
		callbackDecision(t, m, buttons[0][0].Data)
		return nil
	}
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	done := make(chan error, 1)
	go func() {
		approved, err := m.RequestApproval(ctx, "telegram:123", "risk", nil)
		if !approved && err == nil {
			err = errors.New("not approved")
		}
		done <- err
	}()
	select {
	case <-entered:
	case <-ctx.Done():
		t.Fatal(ctx.Err())
	}
	_, err := m.RequestApproval(ctx, "telegram:123", "risk", nil)
	if err == nil || !strings.Contains(err.Error(), "already pending") {
		t.Fatalf("duplicate: %v", err)
	}
	close(release)
	select {
	case err := <-done:
		if err != nil {
			t.Fatal(err)
		}
	case <-ctx.Done():
		t.Fatal(ctx.Err())
	}
	assertNoWaiter(t, m)
	reqID := m.createRequestID("telegram:123", "risk", nil)
	ch, err := m.registerWaiter(reqID)
	if err != nil {
		t.Fatal(err)
	}
	var wg sync.WaitGroup
	for range 20 {
		wg.Add(1)
		go func() { defer wg.Done(); callbackDecision(t, m, "hitl:approve:"+reqID) }()
	}
	m.releaseWaiter(reqID, ch)
	wg.Wait()
	assertNoWaiter(t, m)
}

func assertLifecycleOutcome(t *testing.T, mode string, approved bool, err, failure error) {
	t.Helper()
	expectedApproval := false
	var expectedError error
	switch mode {
	case readErrorMode, "reconcile-error":
		expectedError = failure
	case "cancel", pendingWriteFailure:
		expectedError = context.Canceled
	case "timeout", unsupportedMode:
		if approved || err == nil {
			t.Fatalf("expected failure: %v %v", approved, err)
		}
		return
	case hitlRejected:
	default:
		expectedApproval = true
	}
	if approved != expectedApproval || !errors.Is(err, expectedError) {
		t.Fatalf("approval=%v error=%v, want approval=%v error=%v", approved, err, expectedApproval, expectedError)
	}
}

func TestHITLDecisionDuringPendingWrite(t *testing.T) {
	t.Parallel()
	for _, tc := range []struct {
		action    string
		wantError error
	}{
		{action: "approve"}, {action: "reject", wantError: ErrToolDenied},
	} {
		t.Run(tc.action, func(t *testing.T) {
			t.Parallel()
			store := &lifecycleStore{}
			api := &lifecycleAPI{send: func(context.Context, [][]bot.Button) error { return nil }}
			m := NewHITLManager(api, store, []string{"risk"})
			reqID := m.createRequestID("telegram:123", "risk", nil)
			store.write = func(status string) error {
				if status == hitlPending {
					callbackDecision(t, m, "hitl:"+tc.action+":"+reqID)
				}
				// Both delivery completion and decision writes can fail.
				if status != hitlSending {
					return errors.New("write failed")
				}
				return nil
			}
			ctx, cancel := context.WithTimeout(context.Background(), time.Second)
			defer cancel()
			_, err := m.PreToolHook(ctx, "telegram:123", "risk", nil)
			if !errors.Is(err, tc.wantError) {
				t.Fatalf("got %v, want %v", err, tc.wantError)
			}
			assertNoWaiter(t, m)
		})
	}
}
