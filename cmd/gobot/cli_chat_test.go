//nolint:testpackage // tests unexported chat loop helpers
package main

import (
	"bytes"
	"context"
	"fmt"
	"strings"
	"testing"

	"github.com/allthingscode/gobot/internal/agent"
	"github.com/allthingscode/gobot/internal/config"
	agentctx "github.com/allthingscode/gobot/internal/context"
)

func TestRunChatLoopUsesStableSessionKey(t *testing.T) {
	t.Parallel()

	input := strings.NewReader("hello\nagain\n/exit\n")
	out := &bytes.Buffer{}

	type call struct {
		sessionKey string
		userID     string
		prompt     string
	}
	var calls []call

	opts := chatLoopOptions{
		In:         input,
		Out:        out,
		SessionKey: cliSessionKey("demo"),
		UserID:     "cli-user",
		Dispatch: func(_ context.Context, sessionKey, userID, prompt string) (string, error) {
			calls = append(calls, call{sessionKey: sessionKey, userID: userID, prompt: prompt})
			return "ok:" + prompt, nil
		},
	}

	if err := runChatLoop(context.Background(), opts); err != nil {
		t.Fatalf("runChatLoop returned error: %v", err)
	}

	if len(calls) != 2 {
		t.Fatalf("expected 2 dispatch calls, got %d", len(calls))
	}
	for _, c := range calls {
		if c.sessionKey != "cli:demo" {
			t.Fatalf("expected session key cli:demo, got %q", c.sessionKey)
		}
		if c.userID != "cli-user" {
			t.Fatalf("expected user ID cli-user, got %q", c.userID)
		}
	}
}

func TestRunChatLoopHITLFailClosedContinues(t *testing.T) {
	t.Parallel()

	input := strings.NewReader("danger\nsafe\n/exit\n")
	out := &bytes.Buffer{}
	callCount := 0

	opts := chatLoopOptions{
		In:         input,
		Out:        out,
		SessionKey: cliSessionKey(defaultCLISessionName),
		UserID:     defaultCLIUserID,
		Dispatch: func(_ context.Context, _, _, prompt string) (string, error) {
			callCount++
			if prompt == "danger" {
				return "", fmt.Errorf("runner.Run: %w", fmt.Errorf("%w: HITL: high-risk tool requires approval but session channel cli is unsupported for HITL", agent.ErrToolDenied))
			}
			return "safe reply", nil
		},
	}

	if err := runChatLoop(context.Background(), opts); err != nil {
		t.Fatalf("runChatLoop returned error: %v", err)
	}

	if callCount != 2 {
		t.Fatalf("expected 2 dispatch calls, got %d", callCount)
	}
	got := out.String()
	if !strings.Contains(got, "HITL approval is unavailable in CLI mode") {
		t.Fatalf("expected fail-closed explanation in output, got: %s", got)
	}
	if !strings.Contains(got, "safe reply") {
		t.Fatalf("expected loop to continue after fail-closed error, got: %s", got)
	}
}

func TestRunChatLoopQuitWithoutDispatch(t *testing.T) {
	t.Parallel()

	input := strings.NewReader("/quit\n")
	out := &bytes.Buffer{}
	called := false

	opts := chatLoopOptions{
		In:         input,
		Out:        out,
		SessionKey: cliSessionKey(defaultCLISessionName),
		UserID:     defaultCLIUserID,
		Dispatch: func(_ context.Context, _, _, _ string) (string, error) {
			called = true
			return "", nil
		},
	}

	if err := runChatLoop(context.Background(), opts); err != nil {
		t.Fatalf("runChatLoop returned error: %v", err)
	}
	if called {
		t.Fatalf("dispatch should not be called for /quit")
	}
}

func TestCLISessionKeyDefaults(t *testing.T) {
	t.Parallel()

	if got := cliSessionKey(""); got != "cli:default" {
		t.Fatalf("cliSessionKey(\"\") = %q, want %q", got, "cli:default")
	}
	if got := cliSessionKey("  team-a "); got != "cli:team-a" {
		t.Fatalf("cliSessionKey trim failed: got %q", got)
	}
}

func TestRunChatLoopRequiresDispatch(t *testing.T) {
	t.Parallel()

	opts := chatLoopOptions{
		In:         strings.NewReader("hello\n"),
		Out:        &bytes.Buffer{},
		SessionKey: "cli:test",
		UserID:     "cli-user",
	}

	err := runChatLoop(context.Background(), opts)
	if err == nil {
		t.Fatal("expected error when dispatch is nil")
	}
}

func TestRunChatLoopEOF(t *testing.T) {
	t.Parallel()

	input := strings.NewReader("hello\n")
	out := &bytes.Buffer{}
	calls := 0

	opts := chatLoopOptions{
		In:         input,
		Out:        out,
		SessionKey: "cli:eof",
		UserID:     "user-eof",
		Dispatch: func(_ context.Context, _, _, _ string) (string, error) {
			calls++
			return "ok", nil
		},
	}

	if err := runChatLoop(context.Background(), opts); err != nil {
		t.Fatalf("runChatLoop returned error: %v", err)
	}
	if calls != 1 {
		t.Fatalf("expected 1 dispatch call, got %d", calls)
	}
}

func TestRunChatLoopContextCancelled(t *testing.T) {
	t.Parallel()

	ctx, cancel := context.WithCancel(context.Background())
	cancel()

	opts := chatLoopOptions{
		In:         strings.NewReader("hello\n"),
		Out:        &bytes.Buffer{},
		SessionKey: "cli:ctx",
		UserID:     "user-ctx",
		Dispatch: func(_ context.Context, _, _, _ string) (string, error) {
			return "should-not-run", nil
		},
	}

	if err := runChatLoop(ctx, opts); err != nil {
		t.Fatalf("runChatLoop returned error: %v", err)
	}
}

func TestRunChatLoopDispatchError(t *testing.T) {
	t.Parallel()

	opts := chatLoopOptions{
		In:         strings.NewReader("hello\n"),
		Out:        &bytes.Buffer{},
		SessionKey: "cli:error",
		UserID:     "user-error",
		Dispatch: func(_ context.Context, _, _, _ string) (string, error) {
			return "", fmt.Errorf("dispatch failed")
		},
	}

	err := runChatLoop(context.Background(), opts)
	if err == nil {
		t.Fatal("expected dispatch error")
	}
	if !strings.Contains(err.Error(), "chat: dispatch") {
		t.Fatalf("unexpected error: %v", err)
	}
}

func TestRunChatLoopDefaultsEmptySessionAndUser(t *testing.T) {
	t.Parallel()

	var gotSession string
	var gotUser string

	opts := chatLoopOptions{
		In:         strings.NewReader("hello\n/exit\n"),
		Out:        &bytes.Buffer{},
		SessionKey: "",
		UserID:     " ",
		Dispatch: func(_ context.Context, sessionKey, userID, _ string) (string, error) {
			gotSession = sessionKey
			gotUser = userID
			return "ok", nil
		},
	}

	if err := runChatLoop(context.Background(), opts); err != nil {
		t.Fatalf("runChatLoop returned error: %v", err)
	}
	if gotSession != "cli:default" {
		t.Fatalf("expected default session key, got %q", gotSession)
	}
	if gotUser != "cli-user" {
		t.Fatalf("expected default user ID, got %q", gotUser)
	}
}

func TestCmdChatExecute(t *testing.T) {
	t.Parallel()

	cleanupCalled := false
	cmd := cmdChatWithDeps(chatCommandDeps{
		loadConfig: func() (*config.Config, error) {
			return &config.Config{}, nil
		},
		createSessionManager: func(_ context.Context, _ *config.Config, _ cliHooksMode) (*agent.SessionManager, func(), error) {
			runner := &chatTestRunner{reply: "stubbed reply"}
			return agent.NewSessionManager(runner, nil, "test"), func() { cleanupCalled = true }, nil
		},
	})

	cmd.SetArgs([]string{"--session", "debug"})
	cmd.SetIn(strings.NewReader("hello\n/exit\n"))
	out := &bytes.Buffer{}
	cmd.SetOut(out)

	if err := cmd.Execute(); err != nil {
		t.Fatalf("cmdChat execute failed: %v", err)
	}
	if !cleanupCalled {
		t.Fatal("expected cleanup to be called")
	}
	got := out.String()
	if !strings.Contains(got, "Interactive chat started (cli:debug)") {
		t.Fatalf("expected startup banner with session key, got: %s", got)
	}
	if !strings.Contains(got, "stubbed reply") {
		t.Fatalf("expected reply text in output, got: %s", got)
	}
}

func TestCmdChatErrors(t *testing.T) {
	t.Parallel()

	cmdConfigErr := cmdChatWithDeps(chatCommandDeps{
		loadConfig: func() (*config.Config, error) {
			return nil, fmt.Errorf("config failure")
		},
		createSessionManager: func(_ context.Context, _ *config.Config, _ cliHooksMode) (*agent.SessionManager, func(), error) {
			return nil, nil, nil
		},
	})
	if err := cmdConfigErr.Execute(); err == nil {
		t.Fatal("expected config error")
	}

	cmdFactoryErr := cmdChatWithDeps(chatCommandDeps{
		loadConfig: func() (*config.Config, error) {
			return &config.Config{}, nil
		},
		createSessionManager: func(_ context.Context, _ *config.Config, _ cliHooksMode) (*agent.SessionManager, func(), error) {
			return nil, nil, fmt.Errorf("factory failure")
		},
	})
	if err := cmdFactoryErr.Execute(); err == nil {
		t.Fatal("expected session manager factory error")
	}
}

type chatTestRunner struct {
	reply string
}

func (r *chatTestRunner) Run(_ context.Context, _, _ string, messages []agentctx.StrategicMessage) (string, []agentctx.StrategicMessage, error) {
	text := r.reply
	if text == "" {
		text = "ok"
	}
	reply := text
	messages = append(messages, agentctx.StrategicMessage{
		Role:    agentctx.RoleAssistant,
		Content: &agentctx.MessageContent{Str: &reply},
	})
	return reply, messages, nil
}

func (r *chatTestRunner) RunText(_ context.Context, _, _, _ string) (string, error) {
	return "", nil
}
