package app

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"net"
	"time"

	"github.com/allthingscode/gobot/internal/agent"
	"github.com/allthingscode/gobot/internal/bot"
	"github.com/allthingscode/gobot/internal/config"
	agentctx "github.com/allthingscode/gobot/internal/context"
	"github.com/allthingscode/gobot/internal/reminder"
	"github.com/mymmrac/telego/telegoapi"
)

type reminderRuntime struct {
	store  *reminder.Store
	auth   reminderAuthorization
	worker *reminder.Worker
	cancel context.CancelFunc
	done   chan struct{}
}

func setupReminders(ctx context.Context, cfg *config.Config, runner *AgentRunner, checkpoints agent.CheckpointStore, api *TgAPI) (*reminderRuntime, error) {
	if !cfg.Channels.Telegram.Enabled || api == nil {
		return nil, nil
	}
	mgr, ok := checkpoints.(*agentctx.CheckpointManager)
	if !ok || mgr == nil {
		return nil, errors.New("reminder initialization: pairing database required")
	}
	if _, err := agentctx.NewPairingStore(mgr.DB()); err != nil {
		return nil, fmt.Errorf("reminder initialize pairing: %w", err)
	}
	// Like checkpoint initialization, finish bounded storage setup even when
	// startup is already cancelled; the runtime still records its startup marker.
	initCtx, cancel := context.WithTimeout(context.WithoutCancel(ctx), 5*time.Second)
	defer cancel()
	store, err := reminder.Open(initCtx, cfg.StorageRoot())
	if err != nil {
		return nil, fmt.Errorf("reminder initialization: %w", err)
	}
	runtime := &reminderRuntime{store: store, auth: reminderAuthorization{cfg: cfg, db: mgr.DB()}}
	runtime.worker = &reminder.Worker{
		Store: store, Authorize: runtime.auth.allowed, Transient: transientReminderError,
		Send: func(ctx context.Context, r reminder.Reminder) error {
			return api.SendPlainText(ctx, bot.OutboundMessage{ChatID: r.Owner.ChatID, ThreadID: r.TopicID, Text: r.Text})
		},
	}
	tools := make([]Tool, 0, len(runner.ToolsByName)+3)
	for _, tool := range runner.ToolsByName {
		tools = append(tools, tool)
	}
	for _, name := range []string{createReminderName, listRemindersName, cancelReminderName} {
		tools = append(tools, &reminderTool{name: name, store: store, auth: runtime.auth})
	}
	runner.SetTools(tools)
	wireSubTools(tools)
	return runtime, nil
}

func transientReminderError(err error) bool {
	var apiErr *telegoapi.Error
	if errors.As(err, &apiErr) {
		return apiErr.ErrorCode == 429 || apiErr.ErrorCode >= 500
	}
	var networkError net.Error
	return errors.Is(err, context.Canceled) || errors.As(err, &networkError) || bot.IsTransientError(err)
}

func (r *reminderRuntime) start(ctx context.Context, startErr chan<- error) {
	if r == nil {
		return
	}
	workerCtx, cancel := context.WithCancel(ctx)
	r.cancel, r.done = cancel, make(chan struct{})
	go func() {
		defer close(r.done)
		if err := r.worker.Run(workerCtx); err != nil {
			reportStartupFailure(workerCtx, startErr, "reminders", err)
		}
	}()
}

func (r *reminderRuntime) close() {
	if r == nil {
		return
	}
	if r.cancel != nil {
		r.cancel()
		<-r.done
	}
	if err := r.store.Close(); err != nil {
		slog.Error("reminder storage close failed", "err", err)
	}
}
