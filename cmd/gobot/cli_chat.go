package main

import (
	"bufio"
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"os/signal"
	"strings"
	"syscall"

	"github.com/allthingscode/gobot/internal/agent"
	"github.com/allthingscode/gobot/internal/config"
	"github.com/spf13/cobra"
)

const (
	defaultCLISessionName = "default"
	defaultCLIUserID      = "cli-user"
)

type chatLoopOptions struct {
	In         io.Reader
	Out        io.Writer
	SessionKey string
	UserID     string
	Dispatch   func(ctx context.Context, sessionKey, userID, prompt string) (string, error)
}

type chatCommandDeps struct {
	loadConfig           func() (*config.Config, error)
	createSessionManager func(ctx context.Context, cfg *config.Config, mode cliHooksMode) (*agent.SessionManager, func(), error)
}

func cmdChat() *cobra.Command {
	return cmdChatWithDeps(chatCommandDeps{
		loadConfig:           config.Load,
		createSessionManager: newCLISessionManager,
	})
}

func cmdChatWithDeps(deps chatCommandDeps) *cobra.Command {
	var sessionName string
	var userID string

	cmd := &cobra.Command{
		Use:   "chat",
		Short: "Start an interactive local chat session",
		RunE: func(cmd *cobra.Command, _ []string) error {
			cfg, err := deps.loadConfig()
			if err != nil {
				return fmt.Errorf("config: %w", err)
			}

			mgr, cleanup, err := deps.createSessionManager(cmd.Context(), cfg, cliHooksModeInteractive)
			if err != nil {
				return err
			}
			defer cleanup()

			ctx, cancel := signal.NotifyContext(cmd.Context(), os.Interrupt, syscall.SIGTERM)
			defer cancel()

			opts := chatLoopOptions{
				In:         cmd.InOrStdin(),
				Out:        cmd.OutOrStdout(),
				SessionKey: cliSessionKey(sessionName),
				UserID:     strings.TrimSpace(userID),
				Dispatch:   mgr.Dispatch,
			}
			return runChatLoop(ctx, opts)
		},
	}

	cmd.Flags().StringVar(&sessionName, "session", defaultCLISessionName, "Session name stored as cli:<session>")
	cmd.Flags().StringVar(&userID, "user", defaultCLIUserID, "User ID for this local session")
	return cmd
}

func runChatLoop(ctx context.Context, opts chatLoopOptions) error {
	if opts.Dispatch == nil {
		return fmt.Errorf("chat: dispatch function is required")
	}

	userID, sessionKey := resolveChatIdentity(opts.UserID, opts.SessionKey)
	fmt.Fprintf(opts.Out, "Interactive chat started (%s). Type /exit to quit.\n", sessionKey)

	scanner := bufio.NewScanner(opts.In)
	scanner.Buffer(make([]byte, 0, 64*1024), 1*1024*1024)

	for {
		prompt, stop, err := readChatPrompt(ctx, scanner, opts.Out)
		if err != nil {
			return err
		}
		if stop {
			return nil
		}
		if prompt == "" {
			continue
		}
		if err := processChatPrompt(ctx, opts, sessionKey, userID, prompt); err != nil {
			return err
		}
	}
}

func resolveChatIdentity(userID, sessionKey string) (resolvedUserID, resolvedSessionKey string) {
	resolvedUserID = strings.TrimSpace(userID)
	if resolvedUserID == "" {
		resolvedUserID = defaultCLIUserID
	}

	resolvedSessionKey = strings.TrimSpace(sessionKey)
	if resolvedSessionKey == "" {
		resolvedSessionKey = cliSessionKey(defaultCLISessionName)
	}

	return resolvedUserID, resolvedSessionKey
}

func readChatPrompt(ctx context.Context, scanner *bufio.Scanner, out io.Writer) (prompt string, stop bool, err error) {
	select {
	case <-ctx.Done():
		fmt.Fprintln(out, "\nExiting chat.")
		return "", true, nil
	default:
	}

	fmt.Fprint(out, "> ")
	if !scanner.Scan() {
		if scanErr := scanner.Err(); scanErr != nil {
			return "", false, fmt.Errorf("chat: read input: %w", scanErr)
		}
		fmt.Fprintln(out)
		return "", true, nil
	}

	prompt = strings.TrimSpace(scanner.Text())
	if prompt == "" {
		return "", false, nil
	}
	if isExitCommand(prompt) {
		fmt.Fprintln(out, "Exiting chat.")
		return "", true, nil
	}
	return prompt, false, nil
}

func processChatPrompt(ctx context.Context, opts chatLoopOptions, sessionKey, userID, prompt string) error {
	reply, err := opts.Dispatch(ctx, sessionKey, userID, prompt)
	if err != nil {
		if isHITLFailClosedError(err) {
			fmt.Fprintln(opts.Out, "HITL approval is unavailable in CLI mode. Re-run this request from Telegram.")
			return nil
		}
		return fmt.Errorf("chat: dispatch: %w", err)
	}

	if trimmed := strings.TrimSpace(reply); trimmed != "" {
		fmt.Fprintln(opts.Out, trimmed)
	}
	return nil
}

func cliSessionKey(sessionName string) string {
	name := strings.TrimSpace(sessionName)
	if name == "" {
		name = defaultCLISessionName
	}
	return "cli:" + name
}

func isExitCommand(prompt string) bool {
	switch strings.ToLower(strings.TrimSpace(prompt)) {
	case "/exit", "/quit":
		return true
	default:
		return false
	}
}

func isHITLFailClosedError(err error) bool {
	return errors.Is(err, agent.ErrToolDenied) && strings.Contains(strings.ToLower(err.Error()), "unsupported for hitl")
}
