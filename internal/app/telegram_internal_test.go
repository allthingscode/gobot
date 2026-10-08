//nolint:testpackage // intentionally uses unexported helpers from main package
package app

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/allthingscode/gobot/internal/bot"
	"github.com/allthingscode/gobot/internal/resilience"
	telego "github.com/mymmrac/telego"
	"github.com/mymmrac/telego/telegoapi"
)

func TestTgAPI_HandleMessage(t *testing.T) {
	t.Parallel()
	api := &TgAPI{
		generation: &pollingGeneration{msgChan: make(chan bot.InboundMessage, 10)},
		allowFrom:  map[int64]bool{456: true},
	}

	ctx := context.Background()
	m := &telego.Message{
		MessageID: 123,
		Chat: telego.Chat{
			ID: 456,
		},
		Text: "hello",
		From: &telego.User{
			ID: 789,
		},
	}

	api.handleMessage(ctx, api.generation, m)

	select {
	case msg := <-api.generation.msgChan:
		if msg.Text != "hello" { //nolint:goconst // Test fixture assertion.
			t.Errorf("expected text 'hello', got %q", msg.Text)
		}
		if msg.ChatID != 456 {
			t.Errorf("expected chatID 456, got %d", msg.ChatID)
		}
	default:
		t.Error("expected message in msgChan, but it was empty")
	}
}

func TestTgAPI_HandleUpdate(t *testing.T) {
	t.Parallel()
	api := &TgAPI{
		generation: &pollingGeneration{msgChan: make(chan bot.InboundMessage, 10), cbChan: make(chan bot.InboundCallback, 10)},
		seenMsgs:   sync.Map{},
		allowFrom:  map[int64]bool{1: true},
	}

	ctx := context.Background()

	// Case 1: Message update
	u1 := telego.Update{
		UpdateID: 1,
		Message: &telego.Message{
			MessageID: 1,
			Chat:      telego.Chat{ID: 1},
			Text:      "hi",
		},
	}
	api.handleGenerationUpdate(ctx, api.generation, u1)

	select {
	case <-api.generation.msgChan:
	default:
		t.Error("expected message from u1")
	}

	// Case 2: Callback update (will panic if client is nil and AnswerCallbackQuery is called)
	// We'll skip testing callback query logic here or mock the client.
}

func TestTgAPI_AllowFrom(t *testing.T) {
	t.Parallel()
	api := &TgAPI{
		generation: &pollingGeneration{msgChan: make(chan bot.InboundMessage, 10)},
		allowFrom:  map[int64]bool{123: true},
	}

	ctx := context.Background()

	// Message from allowed chat
	m1 := &telego.Message{MessageID: 1, Chat: telego.Chat{ID: 123}, Text: "ok"}
	api.handleMessage(ctx, api.generation, m1)
	if len(api.generation.msgChan) != 1 {
		t.Error("expected 1 message in channel")
	}

	// Message from disallowed chat
	m2 := &telego.Message{MessageID: 2, Chat: telego.Chat{ID: 999}, Text: "blocked"}
	api.handleMessage(ctx, api.generation, m2)
	if len(api.generation.msgChan) != 1 {
		t.Error("expected still only 1 message in channel")
	}
}

func TestTgAPI_Stop(t *testing.T) {
	t.Parallel()
	api := &TgAPI{}
	api.Stop()
}

// callbackCaller records real telego acknowledgement calls without network access.
type callbackCaller struct {
	t      *testing.T
	api    *TgAPI
	calls  int
	fail   bool
	cancel context.CancelFunc
}

func (c *callbackCaller) Call(_ context.Context, url string, data *telegoapi.RequestData) (*telegoapi.Response, error) {
	c.t.Helper()
	c.calls++
	if !strings.HasSuffix(url, "/answerCallbackQuery") {
		c.t.Errorf("unexpected API method: %s", url)
	}
	var params telego.AnswerCallbackQueryParams
	if err := json.Unmarshal(data.BodyRaw, &params); err != nil {
		c.t.Fatalf("decode acknowledgement: %v", err)
	}
	if params != (telego.AnswerCallbackQueryParams{CallbackQueryID: "callback-id"}) {
		c.t.Errorf("unexpected acknowledgement: %+v", params)
	}
	if c.cancel != nil {
		c.cancel()
	} else if len(c.api.generation.cbChan) != 0 {
		c.t.Error("callback was queued before acknowledgement")
	}
	if c.fail {
		return nil, errors.New("fake acknowledgement failure")
	}
	return &telegoapi.Response{Ok: true, Result: []byte("true")}, nil
}

func newCallbackAPI(t *testing.T, allowFrom map[int64]bool) (*TgAPI, *callbackCaller) {
	t.Helper()
	caller := &callbackCaller{t: t}
	client, err := telego.NewBot("123456789:abcdefghijklmnopqrstuvwxyzABCDEFGHI", telego.WithDiscardLogger(), telego.WithAPICaller(caller))
	if err != nil {
		t.Fatal(err)
	}
	breaker := resilience.New(t.Name(), 1, time.Minute, time.Hour)
	t.Cleanup(breaker.Stop)
	api := &TgAPI{client: client, breaker: breaker, allowFrom: allowFrom,
		generation: &pollingGeneration{msgChan: make(chan bot.InboundMessage, 10), cbChan: make(chan bot.InboundCallback, 10)}}
	caller.api = api
	return api, caller
}

//nolint:paralleltest // breaker registry is shared with ResetAll tests.
func TestTgAPI_CallbackIngress(t *testing.T) {
	ordinary := &telego.Message{MessageID: 42, Chat: telego.Chat{ID: 123}}
	inaccessible := &telego.InaccessibleMessage{MessageID: 42, Chat: telego.Chat{ID: 123}}
	var nilMessage *telego.Message
	var nilInaccessible *telego.InaccessibleMessage
	for _, tt := range []struct {
		name    string
		message telego.MaybeInaccessibleMessage
		allow   map[int64]bool
		admit   bool
	}{
		{"listed chat different sender", ordinary, map[int64]bool{123: true}, true},
		{"listed sender unlisted chat", ordinary, map[int64]bool{789: true}, false},
		{"false whitelist entry", ordinary, map[int64]bool{123: false}, false},
		{"nil whitelist", ordinary, nil, false},
		{"empty whitelist", ordinary, map[int64]bool{}, false},
		{"negative group", &telego.Message{MessageID: 42, Chat: telego.Chat{ID: -123}}, map[int64]bool{-123: true}, true},
		{"negative group unlisted", &telego.Message{MessageID: 42, Chat: telego.Chat{ID: -123}}, map[int64]bool{123: true}, false},
		{"inaccessible listed", inaccessible, map[int64]bool{123: true}, true},
		{"inaccessible unlisted", inaccessible, map[int64]bool{789: true}, false},
		{"inaccessible nil whitelist", inaccessible, nil, false},
		{"inline only", nil, nil, false},
		{"typed nil message", nilMessage, nil, false},
		{"typed nil inaccessible", nilInaccessible, nil, false},
		{"missing chat", &telego.Message{MessageID: 42}, nil, false},
		{"zero chat listed", &telego.Message{Chat: telego.Chat{ID: 0}}, map[int64]bool{0: true}, false},
		{"inaccessible missing chat", &telego.InaccessibleMessage{MessageID: 42}, nil, false},
	} {
		t.Run(tt.name, func(t *testing.T) {
			api, caller := newCallbackAPI(t, tt.allow)
			cb := &telego.CallbackQuery{ID: "callback-id", From: telego.User{ID: 789}, Message: tt.message, InlineMessageID: "inline-id", Data: "approval-data"}
			api.handleGenerationUpdate(context.Background(), api.generation, telego.Update{CallbackQuery: cb})
			if len(api.generation.msgChan) != 0 {
				t.Fatal("callback entered message queue")
			}
			if !tt.admit {
				if len(api.generation.cbChan) != 0 || caller.calls != 0 {
					t.Fatalf("rejected callback queued or acknowledged: queue=%d calls=%d", len(api.generation.cbChan), caller.calls)
				}
				return
			}
			if caller.calls != 1 {
				t.Fatalf("expected one acknowledgement, got %d", caller.calls)
			}
			assertCallbackQueued(t, api, caller, cb)
		})
	}
}

func assertCallbackQueued(t *testing.T, api *TgAPI, caller *callbackCaller, cb *telego.CallbackQuery) {
	t.Helper()
	if len(api.generation.cbChan) != 1 {
		t.Fatalf("expected one acknowledgement and callback: calls=%d queue=%d", caller.calls, len(api.generation.cbChan))
	}
	chatID := cb.Message.GetChat().ID
	want := bot.InboundCallback{ChatID: chatID, MessageID: int64(cb.Message.GetMessageID()), SenderID: cb.From.ID,
		Data: cb.Data, SessionKey: bot.SessionKey(chatID, 0, cb.From.ID)}
	if got := <-api.generation.cbChan; got != want {
		t.Errorf("callback = %+v, want %+v", got, want)
	}
}

//nolint:paralleltest // breaker registry is shared with ResetAll tests.
func TestTgAPI_CallbackNil(t *testing.T) {
	api, caller := newCallbackAPI(t, map[int64]bool{123: true})
	api.handleCallbackQuery(context.Background(), api.generation, nil)
	if caller.calls != 0 || len(api.generation.cbChan) != 0 || len(api.generation.msgChan) != 0 {
		t.Fatal("nil callback acknowledged or queued")
	}
}

//nolint:paralleltest // breaker registry is shared with ResetAll tests.
func TestTgAPI_CallbackAcknowledgement(t *testing.T) {
	for _, open := range []bool{false, true} {
		t.Run(fmt.Sprintf("circuit open=%t", open), func(t *testing.T) {
			api, caller := newCallbackAPI(t, map[int64]bool{123: true})
			caller.fail = true
			if open {
				_ = api.breaker.Execute(func() error { return errors.New("open circuit") })
			}
			cb := &telego.CallbackQuery{ID: "callback-id", From: telego.User{ID: 789},
				Message: &telego.Message{MessageID: 42, Chat: telego.Chat{ID: 123}}, Data: "approval-data"}
			api.handleGenerationUpdate(context.Background(), api.generation, telego.Update{CallbackQuery: cb})
			if open && caller.calls != 0 {
				t.Fatal("open breaker called Telegram")
			}
			assertCallbackQueued(t, api, caller, cb)
			if !open && caller.calls != 1 {
				t.Fatal("expected one failed acknowledgement attempt")
			}
			if api.breaker.State() != "open" {
				t.Fatal("acknowledgement failure did not reach breaker")
			}
		})
	}
}

//nolint:paralleltest // breaker registry is shared with ResetAll tests.
func TestTgAPI_CallbackCancelledFullQueue(t *testing.T) {
	api, caller := newCallbackAPI(t, map[int64]bool{123: true})
	for range cap(api.generation.cbChan) {
		api.generation.cbChan <- bot.InboundCallback{Data: "existing"}
	}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	caller.cancel = cancel // Cancel after the acknowledgement attempt and before the send.
	done := make(chan struct{})
	go func() {
		defer close(done)
		api.handleGenerationUpdate(ctx, api.generation, telego.Update{CallbackQuery: &telego.CallbackQuery{ID: "callback-id",
			Message: &telego.Message{Chat: telego.Chat{ID: 123}}}})
	}()
	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("cancelled callback blocked on full queue")
	}
	if caller.calls != 1 || len(api.generation.cbChan) != cap(api.generation.cbChan) {
		t.Fatal("unexpected acknowledgement or queue size")
	}
	for range cap(api.generation.cbChan) {
		if cb := <-api.generation.cbChan; cb.Data != "existing" {
			t.Fatal("cancelled callback replaced queued entry")
		}
	}
}

func TestTgAPI_MessageIngressMatrix(t *testing.T) {
	t.Parallel()
	for _, tt := range []struct {
		name  string
		allow map[int64]bool
		admit bool
	}{
		{"listed chat", map[int64]bool{123: true, 456: true}, true},
		{"false entries", map[int64]bool{123: false, 456: false}, false},
		{"unlisted chat listed sender", map[int64]bool{789: true}, false},
		{"nil whitelist", nil, false},
		{"empty whitelist", map[int64]bool{}, false},
	} {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			api := &TgAPI{allowFrom: tt.allow, generation: &pollingGeneration{msgChan: make(chan bot.InboundMessage, 10), cbChan: make(chan bot.InboundCallback, 10)}}
			for _, ids := range [][2]int64{{123, 42}, {123, 42}, {456, 42}, {123, 43}} {
				api.handleGenerationUpdate(context.Background(), api.generation, telego.Update{Message: &telego.Message{
					MessageID: int(ids[1]), Chat: telego.Chat{ID: ids[0]}, MessageThreadID: 7,
					From: &telego.User{ID: 789}, Text: "message-text"}})
			}
			api.handleGenerationUpdate(context.Background(), api.generation, telego.Update{Message: &telego.Message{MessageID: 99, Chat: telego.Chat{ID: 123}}})
			assertMessageIngress(t, api, tt.admit)
		})
	}
}

func assertMessageIngress(t *testing.T, api *TgAPI, admit bool) {
	t.Helper()
	if len(api.generation.cbChan) != 0 {
		t.Fatal("message entered callback queue")
	}
	if !admit {
		if len(api.generation.msgChan) != 0 {
			t.Fatal("unlisted messages admitted")
		}
		return
	}
	if len(api.generation.msgChan) != 3 {
		t.Fatalf("expected three distinct nonempty messages, got %d", len(api.generation.msgChan))
	}
	for _, ids := range [][2]int64{{123, 42}, {456, 42}, {123, 43}} {
		want := bot.InboundMessage{ChatID: ids[0], MessageID: ids[1], ThreadID: 7, SenderID: 789, Text: "message-text"}
		if got := <-api.generation.msgChan; got != want {
			t.Errorf("message = %+v, want %+v", got, want)
		}
	}
}

func TestTgAPI_SignedMessageIngress(t *testing.T) {
	t.Parallel()
	for _, tt := range []struct {
		name  string
		allow map[int64]bool
		want  int
	}{
		{"listed negative group", map[int64]bool{-123: true}, 1},
		{"unlisted negative group", map[int64]bool{123: true}, 0},
		{"false negative group", map[int64]bool{-123: false}, 0},
		{"nil", nil, 0}, {"empty", map[int64]bool{}, 0},
	} {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			api := &TgAPI{allowFrom: tt.allow, generation: &pollingGeneration{msgChan: make(chan bot.InboundMessage, 1)}}
			api.handleMessage(context.Background(), api.generation, &telego.Message{MessageID: 42, Chat: telego.Chat{ID: -123}, Text: "group message"})
			if len(api.generation.msgChan) != tt.want {
				t.Fatalf("queued=%d want=%d", len(api.generation.msgChan), tt.want)
			}
		})
	}
}

// pollingCaller exposes each request as a handshake, without ordering sleeps.
type pollingCaller struct {
	requests        chan pollRequest
	mu              sync.Mutex
	acknowledgments int
	acked           chan struct{}
	exitGate        <-chan struct{}
}
type pollRequest struct {
	offset int
	reply  chan pollReply
}
type pollReply struct {
	updates []telego.Update
	err     error
}

func (c *pollingCaller) Call(ctx context.Context, url string, data *telegoapi.RequestData) (*telegoapi.Response, error) {
	if strings.HasSuffix(url, "/answerCallbackQuery") {
		c.mu.Lock()
		c.acknowledgments++
		c.mu.Unlock()
		c.acked <- struct{}{}
		return &telegoapi.Response{Ok: true, Result: []byte("true")}, nil
	}
	var params telego.GetUpdatesParams
	if err := json.Unmarshal(data.BodyRaw, &params); err != nil {
		return nil, fmt.Errorf("decode poll: %w", err)
	}
	request := pollRequest{offset: params.Offset, reply: make(chan pollReply, 1)}
	select {
	case c.requests <- request:
	case <-ctx.Done():
		return nil, fmt.Errorf("poll cancelled: %w", ctx.Err())
	}
	select {
	case reply := <-request.reply:
		if reply.err != nil {
			return nil, reply.err
		}
		result, err := json.Marshal(reply.updates)
		if err != nil {
			return nil, fmt.Errorf("encode poll: %w", err)
		}
		return &telegoapi.Response{Ok: true, Result: result}, nil
	case <-ctx.Done():
		if c.exitGate != nil {
			<-c.exitGate
		}
		return nil, fmt.Errorf("poll cancelled: %w", ctx.Err())
	}
}
func newPollingAPI(t *testing.T) (*TgAPI, *pollingCaller) {
	t.Helper()
	caller := &pollingCaller{requests: make(chan pollRequest), acked: make(chan struct{}, 1000)}
	client, err := telego.NewBot("123456789:abcdefghijklmnopqrstuvwxyzABCDEFGHI", telego.WithDiscardLogger(), telego.WithAPICaller(caller))
	if err != nil {
		t.Fatal(err)
	}
	breaker := resilience.New(t.Name(), 100, time.Minute, time.Hour)
	api := &TgAPI{client: client, breaker: breaker, allowFrom: map[int64]bool{123: true}}
	t.Cleanup(func() { api.Stop(); breaker.Stop() })
	return api, caller
}
func receivePoll(t *testing.T, c *pollingCaller, want int) pollRequest {
	t.Helper()
	select {
	case r := <-c.requests:
		if r.offset != want {
			t.Fatalf("offset=%d want=%d", r.offset, want)
		}
		return r
	case <-time.After(time.Second):
		t.Fatal("poll request timed out")
		return pollRequest{}
	}
}
func awaitGeneration(t *testing.T, g *pollingGeneration) {
	t.Helper()
	select {
	case <-g.done:
	case <-time.After(time.Second):
		t.Fatal("generation did not terminate")
	}
}
func pollingUpdate(id int) telego.Update {
	return telego.Update{UpdateID: id, Message: &telego.Message{MessageID: id, Chat: telego.Chat{ID: 123}, Text: "poll message"}, CallbackQuery: &telego.CallbackQuery{ID: fmt.Sprint(id), From: telego.User{ID: 789}, Message: &telego.Message{MessageID: id, Chat: telego.Chat{ID: 123}}, Data: fmt.Sprint(id)}}
}
func receivePair(t *testing.T, m <-chan bot.InboundMessage, c <-chan bot.InboundCallback, id int) {
	t.Helper()
	select {
	case got := <-m:
		if got.MessageID != int64(id) {
			t.Fatalf("message=%+v", got)
		}
	case <-time.After(time.Second):
		t.Fatal("message timed out")
	}
	select {
	case got := <-c:
		if got.Data != fmt.Sprint(id) {
			t.Fatalf("callback=%+v", got)
		}
	case <-time.After(time.Second):
		t.Fatal("callback timed out")
	}
}

//nolint:paralleltest // shares the breaker registry with ResetAll tests.
func TestTgAPI_PollingAcquisition(t *testing.T) {
	for _, order := range []string{"message first", "callback first", "concurrent"} {
		t.Run(order, func(t *testing.T) {
			testPollingAcquisition(t, order)
		})
	}
}

//nolint:paralleltest // shares the breaker registry with ResetAll tests.
func TestTgAPI_PollingRecovery(t *testing.T) {
	for _, callbackFirst := range []bool{false, true} {
		t.Run(fmt.Sprintf("callback first=%t", callbackFirst), func(t *testing.T) {
			testPollingRecovery(t, callbackFirst)
		})
	}
}

//nolint:paralleltest // shares the breaker registry with ResetAll tests.
func TestTgAPI_PollingCancellation(t *testing.T) {
	for _, phase := range []string{"reserved", "fetch", "full queues", fullCallbacksPhase, "stop reserved", "stop fetch", "cancelled acquisition"} {
		t.Run(phase, func(t *testing.T) {
			testPollingCancellation(t, phase)
		})
	}
}

func testPollingAcquisition(t *testing.T, order string) {
	t.Helper()

	api, caller := newPollingAPI(t)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	var m <-chan bot.InboundMessage
	var c <-chan bot.InboundCallback
	var me, ce error
	switch order {
	case "message first":
		m, me = api.Updates(ctx, 30)
		c, ce = api.Callbacks(ctx)
	case "callback first":
		c, ce = api.Callbacks(ctx)
		m, me = api.Updates(ctx, 30)
	default:
		var wg sync.WaitGroup
		wg.Add(2)
		go func() { defer wg.Done(); m, me = api.Updates(ctx, 30) }()
		go func() { defer wg.Done(); c, ce = api.Callbacks(ctx) }()
		wg.Wait()
	}
	if me != nil || ce != nil {
		t.Fatalf("acquire: %v %v", me, ce)
	}
	again, err := api.Updates(ctx, 30)
	if err != nil || again != m {
		t.Fatal("repeated Updates did not join")
	}
	request := receivePoll(t, caller, 0)
	request.reply <- pollReply{updates: []telego.Update{pollingUpdate(41)}}
	receivePair(t, m, c, 41)
	_ = receivePoll(t, caller, 42)
	cancel()
	api.Stop()
	api.Stop()
	assertPollingClosed(t, m, c)
	caller.mu.Lock()
	defer caller.mu.Unlock()
	if caller.acknowledgments != 1 {
		t.Fatalf("acks=%d", caller.acknowledgments)
	}

}

func testPollingRecovery(t *testing.T, callbackFirst bool) {
	t.Helper()

	api, caller := newPollingAPI(t)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	m, err := api.Updates(ctx, 30)
	if err != nil {
		t.Fatal(err)
	}
	c, err := api.Callbacks(ctx)
	if err != nil {
		t.Fatal(err)
	}
	receivePoll(t, caller, 0).reply <- pollReply{updates: []telego.Update{pollingUpdate(41)}}
	receivePair(t, m, c, 41)
	old := api.generation
	receivePoll(t, caller, 42).reply <- pollReply{err: errors.New("network failure")}
	awaitGeneration(t, old)
	testRepeatedPollingFailures(t, api, caller, ctx, old, callbackFirst)
	m, c = recoverPollingCircuit(t, api, ctx)
	// Clear message dedup so stale suppression can only come from the cursor.
	api.seenMsgs.Clear()
	receivePoll(t, caller, 42).reply <- pollReply{updates: []telego.Update{pollingUpdate(41), pollingUpdate(42)}}
	receivePair(t, m, c, 42)
	_ = receivePoll(t, caller, 43)
	if len(m) != 0 || len(c) != 0 {
		t.Fatal("stale update delivered")
	}
	cancel()
	api.Stop()
	caller.mu.Lock()
	defer caller.mu.Unlock()
	if caller.acknowledgments != 2 {
		t.Fatalf("acks=%d want=2", caller.acknowledgments)
	}

}

func testPollingCancellation(t *testing.T, phase string) {
	t.Helper()

	api, caller := newPollingAPI(t)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	if phase == "cancelled acquisition" {
		cancel()
		if _, err := api.Callbacks(ctx); !errors.Is(err, context.Canceled) {
			t.Fatal(err)
		}
		if _, err := api.Updates(ctx, 30); !errors.Is(err, context.Canceled) {
			t.Fatal(err)
		}
		return
	}
	c, err := api.Callbacks(ctx)
	if err != nil {
		t.Fatal(err)
	}
	g := api.generation
	preparePollingCancellation(t, api, caller, ctx, c, phase)
	if strings.HasPrefix(phase, "stop ") {
		api.Stop()
	} else {
		cancel()
	}
	awaitGeneration(t, g)
	api.Stop()
	api.Stop()
	for range g.msgChan {
	}
	for range c {
	}
	freshCtx, freshCancel := context.WithCancel(context.Background())
	defer freshCancel()
	if _, err := api.Updates(freshCtx, 30); err != nil {
		t.Fatal(err)
	}
	_ = receivePoll(t, caller, api.nextUpdateID)
	if api.generation == g {
		t.Fatal("rerun reused old channels")
	}
	freshCancel()
	api.Stop()

}

func pollingPair(t *testing.T, api *TgAPI, ctx context.Context, callbackFirst bool) (messages <-chan bot.InboundMessage, callbacks <-chan bot.InboundCallback) {
	t.Helper()
	var c <-chan bot.InboundCallback
	var err error
	if callbackFirst {
		c, err = api.Callbacks(ctx)
		if err != nil {
			t.Fatal(err)
		}
	}
	m, err := api.Updates(ctx, 30)
	if err != nil {
		t.Fatal(err)
	}
	if !callbackFirst {
		c, err = api.Callbacks(ctx)
		if err != nil {
			t.Fatal(err)
		}
	}
	return m, c
}

func testRepeatedPollingFailures(t *testing.T, api *TgAPI, caller *pollingCaller, ctx context.Context, old *pollingGeneration, callbackFirst bool) {
	t.Helper()
	for range 2 {

		failedMessages, failedCallbacks := pollingPair(t, api, ctx, callbackFirst)
		g := api.generation
		receivePoll(t, caller, 42).reply <- pollReply{err: errors.New("network failure")}
		awaitGeneration(t, g)
		if _, ok := <-failedMessages; ok {
			t.Fatal("failed message channel open")
		}
		if _, ok := <-failedCallbacks; ok {
			t.Fatal("failed callback channel open")
		}
		if g == old {
			t.Fatal("reused terminal generation")
		}
		old = g
	}
}

func recoverPollingCircuit(t *testing.T, api *TgAPI, ctx context.Context) (messages <-chan bot.InboundMessage, callbacks <-chan bot.InboundCallback) {
	t.Helper()
	// A circuit-open Updates attempt must preserve the callback reservation.
	for range 100 {
		_ = api.breaker.Execute(func() error { return errors.New("open circuit") })
	}
	c, err := api.Callbacks(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if _, err = api.Updates(ctx, 30); !errors.Is(err, resilience.ErrCircuitOpen) {
		t.Fatalf("circuit=%v", err)
	}
	reserved := api.generation
	api.breaker.Reset()
	m, err := api.Updates(ctx, 30)
	if err != nil {
		t.Fatal(err)
	}
	if api.generation != reserved {
		t.Fatal("callback reservation abandoned")
	}
	return m, c
}

func preparePollingCancellation(t *testing.T, api *TgAPI, caller *pollingCaller, ctx context.Context, c <-chan bot.InboundCallback, phase string) {
	t.Helper()
	if phase != "reserved" && phase != "stop reserved" {
		if _, err := api.Updates(ctx, 30); err != nil {
			t.Fatal(err)
		}
		request := receivePoll(t, caller, 0)
		fillPollingQueues(t, caller, request, c, phase)
	}
}

//nolint:paralleltest // shares the breaker registry with ResetAll tests.
func TestTgAPI_WaitsForCancelledPoller(t *testing.T) {
	api, caller := newPollingAPI(t)
	gate := make(chan struct{})
	caller.exitGate = gate
	// Release the fake before cleanup waits for its generation.
	var release sync.Once
	t.Cleanup(func() { release.Do(func() { close(gate) }) })
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	if _, err := api.Updates(ctx, 30); err != nil {
		t.Fatal(err)
	}
	_ = receivePoll(t, caller, 0)
	old := api.generation
	cancel()
	if g, waiting, err := api.acquireGeneration(context.Background(), false); g != old || !waiting || err != nil {
		t.Fatalf("waiting=%t err=%v", waiting, err)
	}
	cancelled, cancelAcquire := context.WithCancel(context.Background())
	cancelAcquire()
	if _, err := api.acquire(cancelled, true); !errors.Is(err, context.Canceled) {
		t.Fatal(err)
	}
	nextCtx, nextCancel := context.WithCancel(context.Background())
	defer nextCancel()
	done := make(chan error, 1)
	go func() { _, err := api.Updates(nextCtx, 30); done <- err }()
	release.Do(func() { close(gate) })
	select {
	case err := <-done:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(time.Second):
		t.Fatal("replacement acquisition blocked")
	}
	awaitGeneration(t, old)
	_ = receivePoll(t, caller, 0)
	nextCancel()
	api.Stop()
}

func assertPollingClosed(t *testing.T, m <-chan bot.InboundMessage, c <-chan bot.InboundCallback) {
	t.Helper()
	if _, ok := <-m; ok {
		t.Fatal("messages not closed")
	}
	if _, ok := <-c; ok {
		t.Fatal("callbacks not closed")
	}
}

func fillPollingQueues(t *testing.T, caller *pollingCaller, request pollRequest, c <-chan bot.InboundCallback, phase string) {
	t.Helper()
	if phase != "full queues" && phase != fullCallbacksPhase {
		return
	}
	updates := make([]telego.Update, 101)
	for i := range updates {
		updates[i] = pollingUpdate(i + 1)
		if phase == fullCallbacksPhase {
			updates[i].Message = nil
		}
	}
	request.reply <- pollReply{updates: updates}
	if phase == fullCallbacksPhase {
		for range 101 {
			awaitPollingAck(t, caller)
		}
		return
	}
	// Draining 100 callbacks proves the message queue has filled before update 101.
	for range 100 {
		select {
		case <-c:
		case <-time.After(time.Second):
			t.Fatal("queue fill timed out")
		}
	}
}
func awaitPollingAck(t *testing.T, caller *pollingCaller) {
	t.Helper()
	select {
	case <-caller.acked:
	case <-time.After(time.Second):
		t.Fatal("callback fill timed out")
	}
}

const fullCallbacksPhase = "full callbacks"
