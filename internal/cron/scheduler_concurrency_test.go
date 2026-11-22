//nolint:testpackage // requires unexported scheduler internals for testing
package cron

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
)

// int64Ptr returns a pointer to the given int64 value.
func int64Ptr(v int64) *int64 {
	return &v
}

// writeJobsJSON encodes jobs into a Store and writes the result to
// <dir>/jobs.json, returning the full path.
func writeJobsJSON(t *testing.T, dir string, jobs []Job) string {
	t.Helper()
	store := Store{Jobs: jobs}
	data, err := store.EncodeJSON()
	if err != nil {
		t.Fatalf("encode jobs: %v", err)
	}
	path := filepath.Join(dir, "jobs.json")
	if err := os.WriteFile(path, data, 0o600); err != nil {
		t.Fatalf("write jobs.json: %v", err)
	}
	return path
}

// concDispatcher is a thread-safe dispatcher used by concurrency tests.
// It is distinct from the mockDispatcher defined in scheduler_test.go.
type concDispatcher struct {
	mu      sync.Mutex
	calls   []Payload
	failIDs map[string]bool
}

func (m *concDispatcher) Dispatch(_ context.Context, p Payload) error {
	m.mu.Lock()
	m.calls = append(m.calls, p)
	m.mu.Unlock()
	if m.failIDs[p.Message] {
		return fmt.Errorf("forced failure: %s", p.Message)
	}
	return nil
}

// heldDispatcher reports entry before blocking every due job on one release gate.
type heldDispatcher struct {
	entered chan Payload
	release chan struct{}
	active  atomic.Int64
	calls   atomic.Int64
}

func (d *heldDispatcher) Dispatch(ctx context.Context, p Payload) error {
	d.active.Add(1)
	defer d.active.Add(-1)
	d.entered <- p
	select {
	case <-d.release:
		d.calls.Add(1)
		return nil
	case <-ctx.Done():
		return fmt.Errorf("held dispatch: %w", ctx.Err())
	}
}

// atomicCountDispatcher counts dispatches using an atomic counter.
type atomicCountDispatcher struct {
	counter *atomic.Int64
}

func (a *atomicCountDispatcher) Dispatch(_ context.Context, _ Payload) error {
	a.counter.Add(1)
	return nil
}

// loadStore reads a jobs.json file and returns a decoded *Store.
func loadStore(t *testing.T, path string) *Store {
	t.Helper()
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read store: %v", err)
	}
	var st Store
	if err := st.DecodeJSON(data); err != nil {
		t.Fatalf("decode store: %v", err)
	}
	return &st
}

// TestScheduler_NoStore_NoPanic verifies that polling against a missing
// jobs.json file does not panic or return an error.
func TestScheduler_NoStore_NoPanic(t *testing.T) {
	t.Parallel()
	s := NewScheduler(filepath.Join(t.TempDir(), "jobs.json"), "", nil)
	s.pollInterval = 1 * time.Millisecond
	if err := s.poll(context.Background()); err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
}

// TestScheduler_DispatchesDueJob asserts that a single enabled job whose
// NextRunAtMS is in the past is dispatched exactly once.
func TestScheduler_DispatchesDueJob(t *testing.T) {
	t.Parallel()
	dir := t.TempDir()
	nowMS := time.Now().UnixNano() / 1e6
	jobs := []Job{
		{
			ID:       "job1",
			Name:     "Job One",
			Enabled:  true,
			Payload:  Payload{Channel: "telegram", To: "123", Message: "hello"},
			Schedule: Schedule{Kind: KindEvery, EveryMS: int64Ptr(60_000)},
			State:    JobState{NextRunAtMS: nowMS - 1000},
		},
	}
	storePath := writeJobsJSON(t, dir, jobs)
	disp := &concDispatcher{}
	s := NewScheduler(storePath, "", disp)
	s.pollInterval = 1 * time.Millisecond
	s.store = loadStore(t, storePath)

	if err := s.poll(context.Background()); err != nil {
		t.Fatalf("poll error: %v", err)
	}

	disp.mu.Lock()
	defer disp.mu.Unlock()
	if len(disp.calls) != 1 {
		t.Fatalf("expected 1 dispatch call, got %d", len(disp.calls))
	}
	if disp.calls[0].Message != "hello" {
		t.Errorf("expected message %q, got %q", "hello", disp.calls[0].Message)
	}
}

// TestScheduler_ConcurrentDispatch_MultipleDueJobs verifies that when
// multiple jobs are due at the same tick they are dispatched concurrently.
// Every job must enter while all previously entered jobs remain held.
func TestScheduler_ConcurrentDispatch_MultipleDueJobs(t *testing.T) {
	t.Parallel()
	dir := t.TempDir()
	nowMS := time.Now().UnixNano() / 1e6
	const n = 5
	jobs := make([]Job, n)
	for i := range jobs {
		jobs[i] = Job{
			ID:       fmt.Sprintf("job%d", i),
			Name:     fmt.Sprintf("Job %d", i),
			Enabled:  true,
			Payload:  Payload{Channel: "telegram", To: "123", Message: fmt.Sprintf("msg%d", i)},
			Schedule: Schedule{Kind: KindEvery, EveryMS: int64Ptr(60_000)},
			State:    JobState{NextRunAtMS: nowMS - 1000},
		}
	}
	storePath := writeJobsJSON(t, dir, jobs)
	disp := &heldDispatcher{entered: make(chan Payload, n), release: make(chan struct{})}
	s := NewScheduler(storePath, "", disp)
	s.pollInterval = 1 * time.Millisecond
	s.store = loadStore(t, storePath)

	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	joined := make(chan struct{})
	var release sync.Once
	go func() { defer close(joined); done <- s.poll(ctx) }()
	t.Cleanup(func() {
		cancel()
		release.Do(func() { close(disp.release) })
		select {
		case <-joined:
		case <-time.After(30 * time.Second):
			t.Error("poll cleanup did not complete")
		}
	})
	watchdog := time.NewTimer(30 * time.Second)
	defer watchdog.Stop()
	seen := awaitHeldDispatches(t, disp.entered, n, watchdog.C)
	if got := disp.active.Load(); got != n {
		t.Errorf("active=%d, want %d", got, n)
	}
	release.Do(func() { close(disp.release) })
	select {
	case err := <-done:
		if err != nil {
			t.Fatal(err)
		}
	case <-watchdog.C:
		t.Fatal("poll did not complete after releasing dispatches")
	}
	if got := disp.calls.Load(); got != n {
		t.Fatalf("completions=%d, want %d", got, n)
	}
	for i, job := range s.store.Jobs {
		assert.True(t, seen[fmt.Sprintf("msg%d", i)], "missing message %d", i)
		assert.EqualValues(t, 1, job.State.RunCount, job.ID)
		assert.EqualValues(t, 1, job.State.SuccessCount, job.ID)
	}
}

// TestScheduler_StateUpdated_AfterDispatch checks that RunCount and
// SuccessCount are both incremented to 1 after a successful poll.
func TestScheduler_StateUpdated_AfterDispatch(t *testing.T) {
	t.Parallel()
	dir := t.TempDir()
	nowMS := time.Now().UnixNano() / 1e6
	jobs := []Job{
		{
			ID:       "job1",
			Name:     "Job One",
			Enabled:  true,
			Payload:  Payload{Channel: "telegram", To: "123", Message: "hello"},
			Schedule: Schedule{Kind: KindEvery, EveryMS: int64Ptr(60_000)},
			State:    JobState{NextRunAtMS: nowMS - 1000},
		},
	}
	storePath := writeJobsJSON(t, dir, jobs)
	disp := &concDispatcher{}
	s := NewScheduler(storePath, "", disp)
	s.store = loadStore(t, storePath)

	if err := s.poll(context.Background()); err != nil {
		t.Fatalf("poll error: %v", err)
	}
	if s.store.Jobs[0].State.RunCount != 1 {
		t.Errorf("expected RunCount 1, got %d", s.store.Jobs[0].State.RunCount)
	}
	if s.store.Jobs[0].State.SuccessCount != 1 {
		t.Errorf("expected SuccessCount 1, got %d", s.store.Jobs[0].State.SuccessCount)
	}
}

// TestScheduler_DisabledJobNotDispatched confirms that a job with
// Enabled=false is never dispatched even when its NextRunAtMS is overdue.
func TestScheduler_DisabledJobNotDispatched(t *testing.T) {
	t.Parallel()
	dir := t.TempDir()
	nowMS := time.Now().UnixNano() / 1e6
	jobs := []Job{
		{
			ID:       "job1",
			Enabled:  false,
			Payload:  Payload{Channel: "telegram", To: "123", Message: "nope"},
			Schedule: Schedule{Kind: KindEvery, EveryMS: int64Ptr(60_000)},
			State:    JobState{NextRunAtMS: nowMS - 1000},
		},
	}
	storePath := writeJobsJSON(t, dir, jobs)
	disp := &concDispatcher{}
	s := NewScheduler(storePath, "", disp)
	s.store = loadStore(t, storePath)

	if err := s.poll(context.Background()); err != nil {
		t.Fatalf("poll error: %v", err)
	}

	disp.mu.Lock()
	defer disp.mu.Unlock()
	if len(disp.calls) != 0 {
		t.Errorf("expected 0 dispatch calls for disabled job, got %d", len(disp.calls))
	}
}

// TestScheduler_AtomicDispatchCounter runs 10 due jobs and verifies the
// final dispatch count using sync/atomic to confirm no data races in the
// counting path.
func TestScheduler_AtomicDispatchCounter(t *testing.T) {
	t.Parallel()
	dir := t.TempDir()
	nowMS := time.Now().UnixNano() / 1e6
	const n = 10
	jobs := make([]Job, n)
	for i := range jobs {
		jobs[i] = Job{
			ID:       fmt.Sprintf("j%d", i),
			Enabled:  true,
			Payload:  Payload{Channel: "telegram", To: "123", Message: fmt.Sprintf("m%d", i)},
			Schedule: Schedule{Kind: KindEvery, EveryMS: int64Ptr(60_000)},
			State:    JobState{NextRunAtMS: nowMS - 1000},
		}
	}
	storePath := writeJobsJSON(t, dir, jobs)

	var callCount atomic.Int64
	disp := &atomicCountDispatcher{counter: &callCount}
	s := NewScheduler(storePath, "", disp)
	s.store = loadStore(t, storePath)

	if err := s.poll(context.Background()); err != nil {
		t.Fatalf("poll error: %v", err)
	}
	if got := callCount.Load(); got != n {
		t.Errorf("expected %d atomic dispatch calls, got %d", n, got)
	}
}

func awaitHeldDispatches(t *testing.T, entered <-chan Payload, n int, watchdog <-chan time.Time) map[string]bool {
	t.Helper()
	seen := make(map[string]bool, n)
	for len(seen) < n {
		select {
		case p := <-entered:
			if seen[p.Message] {
				t.Fatalf("duplicate dispatch: %s", p.Message)
			}
			seen[p.Message] = true
		case <-watchdog:
			t.Fatalf("concurrent dispatch hung: entered=%d of %d", len(seen), n)
		}
	}
	return seen
}
