//nolint:testpackage // requires unexported waitForShutdown/reportStartupFailure
package app

import (
	"bytes"
	"context"
	"errors"
	"github.com/allthingscode/gobot/internal/agent"
	agentctx "github.com/allthingscode/gobot/internal/context"
	"github.com/allthingscode/gobot/internal/memory"
	"github.com/allthingscode/gobot/internal/memory/consolidator"
	"github.com/allthingscode/gobot/internal/memory/vector"
	"github.com/allthingscode/gobot/internal/provider"
	"log/slog"
	"net"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"testing"
	"time"

	"github.com/allthingscode/gobot/internal/config"
)

const subsystemTrigger = "subsystem"

func TestWaitForShutdown_TriggerOrderingAndSubscription(t *testing.T) {
	t.Parallel()
	for _, trigger := range []string{"signal", "parent", subsystemTrigger} {
		t.Run(trigger, func(t *testing.T) {
			t.Parallel()
			checkShutdownTrigger(t, trigger)
		})
	}
}

func checkShutdownTrigger(t *testing.T, trigger string) {
	t.Helper()
	ctx, parentCancel := context.WithCancel(context.Background())
	defer parentCancel()
	// A separate worker context observes the explicit runtime cancel even
	// when the selected parent context is already canceled.
	workerCtx, runtimeCancel := context.WithCancel(context.Background())
	readiness := NewReadiness()
	readiness.SetReady()
	cleanupStarted := make(chan bool, 1)
	release := make(chan struct{})
	var releaseOnce sync.Once
	releaseWorker := func() { releaseOnce.Do(func() { close(release) }) }
	var wg sync.WaitGroup
	wg.Add(1)
	go func() {
		defer wg.Done()
		<-workerCtx.Done()
		cleanupStarted <- readiness.IsReady()
		<-release
	}()
	t.Cleanup(func() { runtimeCancel(); releaseWorker(); wg.Wait() })

	startErr := make(chan error, 1)
	wantErr := errors.New("unique shutdown subsystem failure")
	registered := make(chan chan<- os.Signal, 1)
	stopped := make(chan chan<- os.Signal, 2)
	notify := func(ch chan<- os.Signal, signals ...os.Signal) {
		checkShutdownRegistration(t, ch, signals)
		registered <- ch
	}
	stop := func(ch chan<- os.Signal) { stopped <- ch }
	result := make(chan error, 1)
	go func() {
		result <- waitForShutdownWithSignals(ctx, runtimeCancel, &wg, startErr, readiness, notify, stop)
	}()
	var signals chan<- os.Signal
	select {
	case signals = <-registered:
	case <-time.After(2 * time.Second):
		t.Fatal("shutdown did not register signals")
	}
	if ctx.Err() != nil || workerCtx.Err() != nil {
		t.Fatal("contexts must be live before triggering shutdown")
	}
	switch trigger {
	case "signal":
		signals <- os.Interrupt
	case "parent":
		parentCancel()
	case subsystemTrigger:
		startErr <- wantErr
	}
	checkShutdownDrain(t, cleanupStarted, result, stopped)
	releaseWorker()
	if trigger != subsystemTrigger {
		wantErr = nil
	}
	checkShutdownResult(t, result, wantErr)
	checkShutdownStopped(t, readiness, stopped, signals)
}

func checkShutdownRegistration(t *testing.T, ch chan<- os.Signal, signals []os.Signal) {
	t.Helper()
	if cap(ch) != 1 || len(signals) != 2 || signals[0] != os.Interrupt || signals[1] != syscall.SIGTERM {
		t.Error("expected buffered subscription to Interrupt and SIGTERM")
	}
}

func checkShutdownStopped(t *testing.T, readiness *Readiness, stopped <-chan chan<- os.Signal, signals chan<- os.Signal) {
	t.Helper()
	if readiness.IsReady() {
		t.Error("readiness restored after shutdown")
	}
	if len(stopped) != 1 || <-stopped != signals {
		t.Error("expected exactly one stop on the registered channel")
	}
}

func checkShutdownDrain(t *testing.T, cleanupStarted <-chan bool, result <-chan error, stopped <-chan chan<- os.Signal) {
	t.Helper()
	select {
	case ready := <-cleanupStarted:
		if ready {
			t.Error("worker cleanup began before readiness was cleared")
		}
	case <-time.After(2 * time.Second):
		t.Fatal("runtime cancellation did not start worker cleanup within drain window")
	}
	select {
	case err := <-result:
		t.Fatalf("shutdown returned before worker release: %v", err)
	case <-time.After(20 * time.Millisecond):
	}
	if len(stopped) != 0 {
		t.Error("subscription stopped before wait returned")
	}
}

func checkShutdownResult(t *testing.T, result <-chan error, wantErr error) {
	t.Helper()
	select {
	case err := <-result:
		if wantErr != nil {
			if !errors.Is(err, wantErr) {
				t.Errorf("subsystem identity lost: %v", err)
			}
		} else if err != nil {
			t.Errorf("graceful shutdown returned error: %v", err)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("shutdown did not return promptly after release")
	}
}

// AC2/AC3: a critical subsystem startup error makes waitForShutdown return a
// non-nil error (which propagates to a non-zero process exit) and triggers
// shutdown of the rest via cancel.
func TestWaitForShutdown_ReturnsSubsystemError(t *testing.T) {
	t.Parallel()
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	canceled := false
	spy := func() { canceled = true; cancel() }

	startErr := make(chan error, 1)
	wantErr := errors.New("gateway: listen tcp :8080: bind: address already in use")
	startErr <- wantErr

	var wg sync.WaitGroup
	err := waitForShutdown(ctx, spy, &wg, startErr, nil)
	if err == nil || !strings.Contains(err.Error(), "address already in use") {
		t.Fatalf("expected subsystem error returned, got %v", err)
	}
	if !canceled {
		t.Error("expected context cancel to be triggered on subsystem failure")
	}
}

// AC4: graceful shutdown (context cancellation / signal) returns nil even when
// no subsystem error is present.
func TestWaitForShutdown_GracefulReturnsNil(t *testing.T) {
	t.Parallel()
	ctx, cancel := context.WithCancel(context.Background())
	cancel() // graceful: context already canceled

	var wg sync.WaitGroup
	if err := waitForShutdown(ctx, cancel, &wg, make(chan error, 1), nil); err != nil {
		t.Errorf("graceful shutdown must return nil, got %v", err)
	}
}

// AC4/AC5: reportStartupFailure drops the error when the context is already
// canceled (graceful shutdown is not a failure), and the send is non-blocking
// (full buffer and nil channel must not block).
func TestReportStartupFailure(t *testing.T) {
	t.Parallel()

	// Live context, room in buffer: error is forwarded.
	live := make(chan error, 1)
	cause := errors.New("boom")
	reportStartupFailure(context.Background(), live, "gateway", cause)
	select {
	case err := <-live:
		if !errors.Is(err, cause) {
			t.Errorf("startup failure lost underlying error: %v", err)
		}
		if !strings.Contains(err.Error(), "gateway: boom") {
			t.Errorf("expected wrapped subsystem error, got %v", err)
		}
	default:
		t.Error("expected error to be forwarded on a live context")
	}

	// Canceled context: graceful, error dropped.
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	dropped := make(chan error, 1)
	reportStartupFailure(ctx, dropped, "gateway", errors.New("boom"))
	if len(dropped) != 0 {
		t.Error("expected error to be dropped on a canceled context")
	}

	// Non-blocking: full buffer and nil channel must not block.
	full := make(chan error, 1)
	full <- errors.New("first")
	reportStartupFailure(context.Background(), full, "gateway", errors.New("second"))
	reportStartupFailure(context.Background(), nil, "gateway", errors.New("nil-chan"))
}

// AC3 (realistic): a gateway whose port is already bound reports a startup
// failure on startErr rather than dying silently in the goroutine.
func TestStartGateway_PortConflict_ReportsStartupFailure(t *testing.T) {
	t.Parallel()
	var lc net.ListenConfig
	occupied, err := lc.Listen(context.Background(), "tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("occupy port: %v", err)
	}
	defer func() { _ = occupied.Close() }()
	host, portStr, err := net.SplitHostPort(occupied.Addr().String())
	if err != nil {
		t.Fatalf("split host/port: %v", err)
	}
	port, _ := strconv.Atoi(portStr)

	cfg := &config.Config{}
	cfg.Gateway.Enabled = true
	cfg.Gateway.Host = host
	cfg.Gateway.Port = port

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	startErr := make(chan error, 1)
	var wg sync.WaitGroup

	StartGateway(ctx, cfg, nil, nil, nil, nil, &wg, startErr, nil)

	select {
	case got := <-startErr:
		if !strings.Contains(got.Error(), "gateway") {
			t.Errorf("expected gateway-identified startup error, got %v", got)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("expected a startup failure on the occupied port, got none")
	}
	cancel()
	wg.Wait()
}

type shutdownProvider struct {
	provider.Provider
	started, cancelled, release chan struct{}
}

func (p shutdownProvider) Name() string { return "shutdown-test" }
func (p shutdownProvider) Chat(ctx context.Context, _ provider.ChatRequest) (*provider.ChatResponse, error) {
	close(p.started)
	<-ctx.Done()
	close(p.cancelled)
	<-p.release
	reply := `["cancelled fact must not be indexed"]`
	return &provider.ChatResponse{Message: agentctx.StrategicMessage{Content: &agentctx.MessageContent{Str: &reply}}}, nil
}

type consolidationLifecycleFixture struct {
	owned                       *consolidator.Consolidator
	cancel                      context.CancelFunc
	started, cancelled, release chan struct{}
	store                       *memory.MemoryStore
	vectors                     *vector.Store
	vectorPath                  string
	releaseOnce                 sync.Once
}

func newConsolidationLifecycle(t *testing.T) *consolidationLifecycleFixture {
	t.Helper()
	f := &consolidationLifecycleFixture{started: make(chan struct{}), cancelled: make(chan struct{}), release: make(chan struct{})}
	root := t.TempDir()
	var err error
	f.store, err = memory.NewMemoryStore(root)
	if err != nil {
		t.Fatal(err)
	}

	f.vectorPath = filepath.Join(root, "vectors.gob")
	f.vectors, err = vector.NewStore(f.vectorPath)
	if err != nil {
		t.Fatal(err)
	}
	cfg := &config.Config{}
	runner := NewAgentRunner(shutdownProvider{started: f.started, cancelled: f.cancelled, release: f.release}, "test", "", cfg)
	owner, cancel := context.WithCancel(context.Background())
	f.cancel = cancel
	t.Cleanup(cancel)
	stack := &AgentStack{Runner: runner, MemStore: f.store, VecStore: f.vectors}
	h := &DispatchHandler{}
	f.owned = SetupConsolidator(owner, cfg, stack, &agent.SessionManager{}, h, nil, nil)
	t.Cleanup(func() {
		f.releaseOnce.Do(func() { close(f.release) })
		f.cancel()
		ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
		defer cancel()
		if err := f.owned.Shutdown(ctx); err != nil {
			t.Error(err)
		}
		_ = f.store.Close()
	})
	if h.Consolidator != f.owned {
		t.Fatal("setup published different consolidator")
	}
	f.owned.ConsolidateAsync("session", strings.Repeat("reply ", 20))
	awaitAppWorker(t, f.started)
	return f
}

func (f *consolidationLifecycleFixture) cleanup(t *testing.T) {
	t.Helper()
	if err := f.vectors.Save(); err != nil {
		t.Error(err)
	}
	if err := f.store.Close(); err != nil {
		t.Error(err)
	}
}

func TestConsolidationLifecycleJoinsBeforeCleanup(t *testing.T) {
	t.Parallel()
	for _, trigger := range []string{"signal", "parent", subsystemTrigger} {
		t.Run(trigger, func(t *testing.T) { t.Parallel(); checkConsolidationLifecycle(t, trigger) })
	}
}
func checkConsolidationLifecycle(t *testing.T, trigger string) {
	t.Helper()
	f := newConsolidationLifecycle(t)
	cause := errors.New("critical subsystem")
	result := make(chan error, 1)
	cleaned := make(chan struct{})
	go func() {
		result <- runWithStackCleanup(func() { f.cleanup(t); close(cleaned) }, func() error {
			return runOwnedConsolidation(f.owned, f.cancel, 2*time.Second, func() error {
				ctx, cancel := context.WithCancel(context.Background())
				defer cancel()
				failures := make(chan error, 1)
				signals := make(chan os.Signal, 1)
				switch trigger {
				case "signal":
					signals <- os.Interrupt
				case "parent":
					cancel()
				case subsystemTrigger:
					failures <- cause
				}
				var wg sync.WaitGroup
				return waitForShutdownTrigger(ctx, f.cancel, &wg, failures, NewReadiness(), signals, time.Second)
			})
		})
	}()
	awaitAppWorker(t, f.cancelled)
	select {
	case <-cleaned:
		t.Fatal("cleanup ran while worker blocked")
	default:
	}
	if _, err := os.Stat(f.vectorPath); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("vector saved before join: %v", err)
	}
	if err := f.store.Index("session:session", "stores remain usable while worker owns them"); err != nil {
		t.Fatal(err)
	}
	f.releaseOnce.Do(func() { close(f.release) })
	checkLifecycleResult(t, result, trigger, cause)
	awaitAppWorker(t, cleaned)
	if _, err := os.Stat(f.vectorPath); err != nil {
		t.Fatalf("cleanup did not save vector store: %v", err)
	}
	if err := f.store.Index("late", "closed"); err == nil {
		t.Fatal("SQLite remained open after join")
	}
}

func checkLifecycleResult(t *testing.T, result <-chan error, trigger string, cause error) {
	t.Helper()
	select {
	case err := <-result:
		if trigger == subsystemTrigger {
			if !errors.Is(err, cause) {
				t.Fatalf("lost subsystem error: %v", err)
			}
		} else if err != nil {
			t.Fatal(err)
		}
	case <-time.After(3 * time.Second):
		t.Fatal("shutdown did not finish")
	}
}

//nolint:paralleltest // captures the global application logger without parallel mutation.
func TestConsolidationTimeoutRetainsStoresAndSubsystemError(t *testing.T) {
	f := newConsolidationLifecycle(t)
	var logs bytes.Buffer
	previous := slog.Default()
	slog.SetDefault(slog.New(slog.NewTextHandler(&logs, nil)))
	defer slog.SetDefault(previous)
	cause := errors.New("startup failed")
	cleaned := 0
	err := runWithStackCleanup(func() { cleaned++; f.cleanup(t) }, func() error {
		return runOwnedConsolidation(f.owned, f.cancel, 10*time.Millisecond, func() error { return cause })
	})
	if !errors.Is(err, cause) || !errors.Is(err, consolidator.ErrDrainTimeout) || !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("lost error causes: %v", err)
	}
	awaitAppWorker(t, f.cancelled)
	if cleaned != 0 {
		t.Fatal("disposed stores after timeout")
	}
	if !strings.Contains(logs.String(), "retaining memory and vector stores") {
		t.Fatalf("missing retained-store event: %s", logs.String())
	}
	if err := f.store.Index("session:session", "still open after timeout"); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(f.vectorPath); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("vector cleanup ran: %v", err)
	}
	f.releaseOnce.Do(func() { close(f.release) })
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	if err := f.owned.Shutdown(ctx); err != nil {
		t.Fatal(err)
	}
	f.cleanup(t)
}

func TestStackCleanupNormalAndEarlyError(t *testing.T) {
	t.Parallel()
	for _, cause := range []error{nil, errors.New("early startup failure")} {
		calls := 0
		got := runWithStackCleanup(func() { calls++ }, func() error { return cause })
		if !errors.Is(got, cause) || calls != 1 {
			t.Fatalf("cleanup=%d err=%v", calls, got)
		}
		if got := shutdownConsolidation(nil, cause, time.Second); !errors.Is(got, cause) {
			t.Fatal("nil owner lost error")
		}
	}
}
