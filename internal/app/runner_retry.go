package app

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"strings"
	"time"

	"github.com/allthingscode/gobot/internal/bot"
	"github.com/allthingscode/gobot/internal/provider"
	"github.com/allthingscode/gobot/internal/resilience"
)

// RetryChat calls prov.Chat with exponential backoff on transient errors.
func (r *AgentRunner) RetryChat(ctx context.Context, sessionKey string, req provider.ChatRequest) (*provider.ChatResponse, error) {
	const maxGenRetries = 3
	const initialDelay = 1 * time.Second
	const maxDelay = 30 * time.Second

	delay := initialDelay
	var lastErr error
	for attempt := 0; attempt <= maxGenRetries; attempt++ {
		if attempt > 0 {
			if err := r.waitBeforeRetry(ctx, lastErr, attempt, &delay, maxDelay); err != nil {
				return nil, err
			}
		}

		resp, err := r.attemptChat(ctx, sessionKey, attempt, req)
		if err == nil {
			return resp, nil
		}

		if !r.shouldRetry(err) {
			return nil, err
		}
		lastErr = err
	}
	return nil, fmt.Errorf("%d retries exhausted: %w", maxGenRetries, lastErr)
}

func (r *AgentRunner) waitBeforeRetry(ctx context.Context, lastErr error, attempt int, delay *time.Duration, maxDelay time.Duration) error {
	slog.Warn("runner: transient error, retrying", "attempt", attempt, "delay", *delay, "err", lastErr)
	select {
	case <-ctx.Done():
		return fmt.Errorf("context: %w", ctx.Err())
	case <-time.After(*delay):
	}
	*delay *= 2
	if *delay > maxDelay {
		*delay = maxDelay
	}
	return nil
}

func (r *AgentRunner) attemptChat(ctx context.Context, sessionKey string, attempt int, req provider.ChatRequest) (*provider.ChatResponse, error) {
	if waitErr := r.Limiter.Wait(ctx); waitErr != nil {
		return nil, fmt.Errorf("rate limit wait: %w", waitErr)
	}

	var resp *provider.ChatResponse
	fn := func(ctx context.Context) error {
		return r.Breaker.Execute(func() error {
			var callErr error
			resp, callErr = r.Prov.Chat(ctx, req)
			if callErr != nil {
				return fmt.Errorf("provider chat: %w", callErr)
			}
			return nil
		})
	}

	var err error
	if r.Tracer != nil {
		err = r.Tracer.TraceProviderCall(ctx, sessionKey, attempt, fn)
	} else {
		err = fn(ctx)
	}

	if err == nil {
		if r.Tracer != nil && resp != nil && resp.Usage.TotalTokens > 0 {
			r.Tracer.RecordTokens(ctx, int64(resp.Usage.TotalTokens))
		}
		return resp, nil
	}
	return nil, err
}

func (r *AgentRunner) shouldRetry(err error) bool {
	if err == nil {
		return false
	}
	if errors.Is(err, resilience.ErrCircuitOpen) {
		return false
	}
	if isRateLimitError(err) {
		return true
	}
	return bot.IsTransientError(err)
}

func isRateLimitError(err error) bool {
	msg := strings.ToLower(err.Error())
	return strings.Contains(msg, "429") ||
		strings.Contains(msg, "resource_exhausted") ||
		strings.Contains(msg, "rate limit")
}
