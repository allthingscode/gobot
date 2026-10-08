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
		msgChan:   make(chan bot.InboundMessage, 10),
		allowFrom: map[int64]bool{456: true},
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

	api.handleMessage(ctx, m)

	select {
	case msg := <-api.msgChan:
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
		msgChan:   make(chan bot.InboundMessage, 10),
		cbChan:    make(chan bot.InboundCallback, 10),
		seenMsgs:  sync.Map{},
		allowFrom: map[int64]bool{1: true},
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
	api.handleUpdate(ctx, u1)

	select {
	case <-api.msgChan:
	default:
		t.Error("expected message from u1")
	}

	// Case 2: Callback update (will panic if client is nil and AnswerCallbackQuery is called)
	// We'll skip testing callback query logic here or mock the client.
}

func TestTgAPI_AllowFrom(t *testing.T) {
	t.Parallel()
	api := &TgAPI{
		msgChan:   make(chan bot.InboundMessage, 10),
		allowFrom: map[int64]bool{123: true},
	}

	ctx := context.Background()

	// Message from allowed chat
	m1 := &telego.Message{MessageID: 1, Chat: telego.Chat{ID: 123}, Text: "ok"}
	api.handleMessage(ctx, m1)
	if len(api.msgChan) != 1 {
		t.Error("expected 1 message in channel")
	}

	// Message from disallowed chat
	m2 := &telego.Message{MessageID: 2, Chat: telego.Chat{ID: 999}, Text: "blocked"}
	api.handleMessage(ctx, m2)
	if len(api.msgChan) != 1 {
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
	} else if len(c.api.cbChan) != 0 {
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
		msgChan: make(chan bot.InboundMessage, 10), cbChan: make(chan bot.InboundCallback, 10)}
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
			api.handleUpdate(context.Background(), telego.Update{CallbackQuery: cb})
			if len(api.msgChan) != 0 {
				t.Fatal("callback entered message queue")
			}
			if !tt.admit {
				if len(api.cbChan) != 0 || caller.calls != 0 {
					t.Fatalf("rejected callback queued or acknowledged: queue=%d calls=%d", len(api.cbChan), caller.calls)
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
	if len(api.cbChan) != 1 {
		t.Fatalf("expected one acknowledgement and callback: calls=%d queue=%d", caller.calls, len(api.cbChan))
	}
	chatID := cb.Message.GetChat().ID
	want := bot.InboundCallback{ChatID: chatID, MessageID: int64(cb.Message.GetMessageID()), SenderID: cb.From.ID,
		Data: cb.Data, SessionKey: bot.SessionKey(chatID, 0, cb.From.ID)}
	if got := <-api.cbChan; got != want {
		t.Errorf("callback = %+v, want %+v", got, want)
	}
}

//nolint:paralleltest // breaker registry is shared with ResetAll tests.
func TestTgAPI_CallbackNil(t *testing.T) {
	api, caller := newCallbackAPI(t, map[int64]bool{123: true})
	api.handleCallbackQuery(context.Background(), nil)
	if caller.calls != 0 || len(api.cbChan) != 0 || len(api.msgChan) != 0 {
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
			api.handleUpdate(context.Background(), telego.Update{CallbackQuery: cb})
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
	for range cap(api.cbChan) {
		api.cbChan <- bot.InboundCallback{Data: "existing"}
	}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	caller.cancel = cancel // Cancel after the acknowledgement attempt and before the send.
	done := make(chan struct{})
	go func() {
		defer close(done)
		api.handleUpdate(ctx, telego.Update{CallbackQuery: &telego.CallbackQuery{ID: "callback-id",
			Message: &telego.Message{Chat: telego.Chat{ID: 123}}}})
	}()
	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("cancelled callback blocked on full queue")
	}
	if caller.calls != 1 || len(api.cbChan) != cap(api.cbChan) {
		t.Fatal("unexpected acknowledgement or queue size")
	}
	for range cap(api.cbChan) {
		if cb := <-api.cbChan; cb.Data != "existing" {
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
			api := &TgAPI{allowFrom: tt.allow, msgChan: make(chan bot.InboundMessage, 10), cbChan: make(chan bot.InboundCallback, 10)}
			for _, ids := range [][2]int64{{123, 42}, {123, 42}, {456, 42}, {123, 43}} {
				api.handleUpdate(context.Background(), telego.Update{Message: &telego.Message{
					MessageID: int(ids[1]), Chat: telego.Chat{ID: ids[0]}, MessageThreadID: 7,
					From: &telego.User{ID: 789}, Text: "message-text"}})
			}
			api.handleUpdate(context.Background(), telego.Update{Message: &telego.Message{MessageID: 99, Chat: telego.Chat{ID: 123}}})
			assertMessageIngress(t, api, tt.admit)
		})
	}
}

func assertMessageIngress(t *testing.T, api *TgAPI, admit bool) {
	t.Helper()
	if len(api.cbChan) != 0 {
		t.Fatal("message entered callback queue")
	}
	if !admit {
		if len(api.msgChan) != 0 {
			t.Fatal("unlisted messages admitted")
		}
		return
	}
	if len(api.msgChan) != 3 {
		t.Fatalf("expected three distinct nonempty messages, got %d", len(api.msgChan))
	}
	for _, ids := range [][2]int64{{123, 42}, {456, 42}, {123, 43}} {
		want := bot.InboundMessage{ChatID: ids[0], MessageID: ids[1], ThreadID: 7, SenderID: 789, Text: "message-text"}
		if got := <-api.msgChan; got != want {
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
			api := &TgAPI{allowFrom: tt.allow, msgChan: make(chan bot.InboundMessage, 1)}
			api.handleMessage(context.Background(), &telego.Message{MessageID: 42, Chat: telego.Chat{ID: -123}, Text: "group message"})
			if len(api.msgChan) != tt.want {
				t.Fatalf("queued=%d want=%d", len(api.msgChan), tt.want)
			}
		})
	}
}
