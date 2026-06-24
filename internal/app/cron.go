package app

import (
	"context"
	"log/slog"
	"path/filepath"

	"github.com/allthingscode/gobot/internal/agent"
	"github.com/allthingscode/gobot/internal/bot"
	"github.com/allthingscode/gobot/internal/config"
	"github.com/allthingscode/gobot/internal/cron"
	"github.com/allthingscode/gobot/internal/memory/vector"
	"github.com/allthingscode/gobot/internal/provider"
	"github.com/allthingscode/gobot/internal/reporter"
)

const (
	chanTelegram         = "telegram"
	chanEmail            = "email"
	morningBriefingJobID = "morning_briefing"
)

// CronDispatcher implements cron.Dispatcher.
// It routes job payloads to the agent SessionManager and sends
// any non-empty response back via the Telegram bot.
type CronDispatcher struct {
	mgr         *agent.SessionManager
	b           *bot.Bot
	storageRoot string
	secretsRoot string
	userEmail   string
	shutdownCh  <-chan struct{} // closed when the application is shutting down

	vecStore     *vector.Store
	embedProv    vector.EmbeddingProvider
	workspaceDir string

	cfg              *config.Config
	tmgr             *reporter.TemplateManager
	runnerFactory    func(prov provider.Provider, model, systemPrompt string) *AgentRunner
	failureEmailHook func(ctx context.Context, p cron.Payload, recipient, body string)
	dispatchHook     func(ctx context.Context, sessionKey, msg string) (string, error)
	guardHook        func(sessionKey, response string) error
}

// NewCronDispatcher initializes a new CronDispatcher using the given stack and bot.
func NewCronDispatcher(cfg *config.Config, mgr *agent.SessionManager, stack *AgentStack, b *bot.Bot, tmgr *reporter.TemplateManager) *CronDispatcher {
	return &CronDispatcher{
		mgr:          mgr,
		b:            b,
		storageRoot:  cfg.StorageRoot(),
		secretsRoot:  cfg.SecretsRoot(),
		userEmail:    cfg.Runtime.UserEmail,
		vecStore:     stack.VecStore,
		embedProv:    stack.EmbedProv,
		workspaceDir: cfg.WorkspacePath(""),
		cfg:          cfg,
		tmgr:         tmgr,
		runnerFactory: func(prov provider.Provider, model, systemPrompt string) *AgentRunner {
			return NewAgentRunner(prov, model, systemPrompt, cfg)
		},
	}
}

// Run starts the cron scheduler and blocks until ctx is canceled.
func (cd *CronDispatcher) Run(ctx context.Context) {
	cd.shutdownCh = ctx.Done()
	scheduler := cron.NewScheduler(
		filepath.Join(cd.storageRoot, "workspace", "jobs.json"),
		filepath.Join(cd.storageRoot, "workspace", "jobs"),
		cd,
	)
	if err := scheduler.Run(ctx); err != nil {
		slog.Error("cron: scheduler exited with error", "err", err)
	}
}

// Dispatch routes a cron job payload to the agent and sends the reply.
func (cd *CronDispatcher) Dispatch(ctx context.Context, p cron.Payload) error {
	p.Message = resolvePlaceholders(p.Message)

	if cd.handleSystemJob(ctx, p) {
		return nil
	}

	channel, to, silent := cron.ResolveRoutableChannel(p, cd.storageRoot)

	// F-121: Handle specialist dispatch if Agent is specified
	if p.Agent != "" {
		return cd.dispatchSpecialist(ctx, p, channel, to, silent)
	}

	if silent {
		return cd.dispatchSilent(ctx, p, to)
	}

	switch channel {
	case chanEmail:
		return cd.dispatchEmail(ctx, p, to)
	case chanTelegram:
		if to != "" {
			return cd.dispatchTelegram(ctx, p, to)
		}
	}

	slog.Warn("unroutable cron job", "channel", channel, "to", to)
	return nil
}

func (cd *CronDispatcher) handleSystemJob(ctx context.Context, p cron.Payload) bool {
	if p.Message != "[SYSTEM] INDEX_WORKSPACE" {
		return false
	}

	if cd.vecStore != nil && cd.embedProv != nil && cd.workspaceDir != "" {
		slog.Info("cron: starting workspace vector indexing")
		err := vector.IndexWorkspaceMarkdown(ctx, cd.vecStore, cd.workspaceDir, func(c context.Context, text string) ([]float32, error) {
			return cd.embedProv.Embed(c, text)
		})
		if err != nil {
			slog.Error("cron: vector index error", "err", err)
		} else {
			slog.Info("cron: workspace vector indexing complete")
		}
	} else {
		slog.Warn("cron: vector store not initialized, skipping INDEX_WORKSPACE")
	}
	return true
}
