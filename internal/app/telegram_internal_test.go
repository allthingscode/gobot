//nolint:testpackage // intentionally uses unexported helpers from main package
package app

import (
	"context"
	"sync"
	"testing"

	"github.com/allthingscode/gobot/internal/bot"
	telego "github.com/mymmrac/telego"
)

func TestTgAPI_HandleMessage(t *testing.T) {
	t.Parallel()
	api := &TgAPI{
		msgChan:   make(chan bot.InboundMessage, 10),
		allowFrom: make(map[int64]bool),
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
		if msg.Text != "hello" {
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
		msgChan:  make(chan bot.InboundMessage, 10),
		cbChan:   make(chan bot.InboundCallback, 10),
		seenMsgs: sync.Map{},
	}

	ctx := context.Background()
	
	// Case 1: Message update
	u1 := telego.Update{
		UpdateID: 1,
		Message: &telego.Message{
			MessageID: 1,
			Chat: telego.Chat{ID: 1},
			Text: "hi",
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
