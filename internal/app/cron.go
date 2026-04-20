package app

import (
	"context"
	"fmt"
	"log/slog"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"github.com/allthingscode/gobot/internal/agent"
	"github.com/allthingscode/gobot/internal/bot"
	"github.com/allthingscode/gobot/internal/config"
	"github.com/allthingscode/gobot/internal/cron"
	"github.com/allthingscode/gobot/internal/integrations/google"
	"github.com/allthingscode/gobot/internal/memory/vector"
	"github.com/allthingscode/gobot/internal/observability"
	"github.com/allthingscode/gobot/internal/provider"
)

const (
	chanTelegram = "telegram"
	chanEmail    = "email"
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

	vecStore     *vector.Store
	embedProv    vector.EmbeddingProvider
	workspaceDir string

	cfg           *config.Config
	runnerFactory func(prov provider.Provider, model, systemPrompt string) *AgentRunner
}

// NewCronDispatcher initializes a new CronDispatcher using the given stack and bot.
func NewCronDispatcher(cfg *config.Config, stack *AgentStack, b *bot.Bot, tracer *observability.DispatchTracer) *CronDispatcher {
	mgr := stack.NewSessionManager(cfg, nil, tracer)
	return &CronDispatcher{
		mgr:          mgr,
		b:            b,
		storageRoot:  cfg.StorageRoot(),
		secretsRoot:  cfg.SecretsRoot(),
		userEmail:    cfg.Strategic.UserEmail,
		vecStore:     stack.VecStore,
		embedProv:    stack.EmbedProv,
		workspaceDir: cfg.WorkspacePath(""),
		cfg:          cfg,
		runnerFactory: func(prov provider.Provider, model, systemPrompt string) *AgentRunner {
			return NewAgentRunner(prov, model, systemPrompt, cfg)
		},
	}
}

// Run starts the cron scheduler and blocks until ctx is canceled.
func (cd *CronDispatcher) Run(ctx context.Context) {
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

func (cd *CronDispatcher) prepareSpecialistRunner(agentName string, spec config.SpecialistConfig) (*AgentRunner, error) {
	prov, err := provider.Get(cd.cfg.SpecialistProvider(agentName))
	if err != nil {
		return nil, fmt.Errorf("specialist provider: %w", err)
	}

	systemPrompt := DefaultSpecialistPrompt(agentName)
	runner := cd.runnerFactory(prov, spec.Model, systemPrompt)

	if cd.mgr != nil {
		if ar, ok := cd.mgr.GetRunner().(*AgentRunner); ok {
			runner.MemStore = ar.MemStore
		}
	}
	return runner, nil
}

func (cd *CronDispatcher) dispatchSpecialist(ctx context.Context, p cron.Payload, channel, to string, silent bool) error {
	spec, ok := cd.cfg.Agents.Specialists[p.Agent]
	if !ok {
		err := fmt.Errorf("unknown specialist: %s", p.Agent)
		slog.Error("cron: specialist dispatch failed", "agent", p.Agent, "err", err)
		return err
	}

	runner, err := cd.prepareSpecialistRunner(p.Agent, spec)
	if err != nil {
		return err
	}

	sessionKey := "cron:" + p.Agent + ":" + p.ID
	if to != "" {
		sessionKey += ":" + to
	}

	slog.Info("dispatching specialist cron job", "agent", p.Agent, "session", sessionKey, "channel", channel)
	response, err := runner.RunText(ctx, sessionKey, "[AUTONOMOUS] "+p.Message, "")
	if err != nil {
		return fmt.Errorf("specialist run: %w", err)
	}

	if silent || response == "" {
		return nil
	}

	cd.sendSpecialistResponse(ctx, p, channel, to, response)
	return nil
}

func (cd *CronDispatcher) sendSpecialistResponse(ctx context.Context, p cron.Payload, channel, to, response string) {
	switch channel {
	case chanEmail:
		recipient := to
		if recipient == "" {
			recipient = cd.userEmail
		}
		if recipient != "" {
			cd.sendEmailResponse(ctx, p, recipient, response)
		}
	case chanTelegram:
		if to != "" {
			cd.sendTelegramResponse(ctx, to, response)
		}
	}
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

func (cd *CronDispatcher) dispatchSilent(ctx context.Context, p cron.Payload, to string) error {
	if to == "" {
		slog.Warn("unroutable silent cron job", "to", to)
		return nil
	}
	sessionKey := "cron:" + to
	slog.Info("dispatching cron job", "session", sessionKey, "silent", true)
	_, err := cd.mgr.Dispatch(ctx, sessionKey, "", "[SILENT] [AUTONOMOUS] "+p.Message)
	if err != nil {
		return fmt.Errorf("dispatch silent: %w", err)
	}
	return nil
}

func (cd *CronDispatcher) dispatchEmail(ctx context.Context, p cron.Payload, to string) error {
	recipient := to
	if recipient == "" {
		recipient = cd.userEmail
	}
	if recipient == "" {
		slog.Warn("unroutable cron job: email recipient not set", "job", p.Message)
		return nil
	}

	jobID := p.ID
	if jobID == "" {
		jobID = "unknown"
	}
	sessionKey := "cron:" + jobID + ":" + chanEmail + ":" + recipient
	slog.Info("dispatching cron job", "session", sessionKey, "channel", chanEmail)
	response, err := cd.mgr.Dispatch(ctx, sessionKey, "", "[AUTONOMOUS] "+p.Message)
	if err != nil {
		return fmt.Errorf("dispatch email: %w", err)
	}

	if response != "" {
		cd.sendEmailResponse(ctx, p, recipient, response)
	}
	return nil
}

func (cd *CronDispatcher) sendEmailResponse(ctx context.Context, p cron.Payload, recipient, response string) {
	gmailSecrets := filepath.Join(cd.secretsRoot, "gmail")
	svc, err := google.NewService(ctx, gmailSecrets)
	if err != nil {
		slog.Error("failed to initialize gmail service for cron", "err", err)
		return
	}
	subject := resolveEmailSubject(p)
	if err := svc.Send(ctx, recipient, subject, response); err != nil {
		slog.Error("failed to send cron response via email", "err", err, "to", recipient)
	}
}

func (cd *CronDispatcher) dispatchTelegram(ctx context.Context, p cron.Payload, to string) error {
	sessionKey := "cron:" + to
	slog.Info("dispatching cron job", "session", sessionKey, "silent", false)
	response, err := cd.mgr.Dispatch(ctx, sessionKey, "", "[AUTONOMOUS] "+p.Message)
	if err != nil {
		return fmt.Errorf("dispatch telegram: %w", err)
	}

	if response != "" {
		cd.sendTelegramResponse(ctx, to, response)
	}
	return nil
}

func (cd *CronDispatcher) sendTelegramResponse(ctx context.Context, to, response string) {
	chatID, threadID, err := parseSessionKey(to)
	if err != nil {
		slog.Error("failed to parse session key for reply", "session", to, "err", err)
		return
	}
	out := bot.OutboundMessage{
		ChatID:   chatID,
		ThreadID: threadID,
		Text:     response,
	}
	if err := cd.b.Send(ctx, out); err != nil {
		slog.Error("failed to send cron response", "err", err, "session", to)
	}
}

// Alert sends a failure notification directly via Telegram, bypassing the agent
// runner. This prevents a cascading failure when the runner itself is the error source.
func (cd *CronDispatcher) Alert(ctx context.Context, p cron.Payload) error {
	_, to, _ := cron.ResolveRoutableChannel(p, cd.storageRoot)
	if to == "" {
		slog.Warn("CronDispatcher.Alert: unroutable payload, dropping", "channel", p.Channel)
		return nil
	}
	chatID, threadID, err := parseSessionKey(to)
	if err != nil {
		return fmt.Errorf("CronDispatcher.Alert: %w", err)
	}
	if err := cd.b.Send(ctx, bot.OutboundMessage{
		ChatID:   chatID,
		ThreadID: threadID,
		Text:     p.Message,
	}); err != nil {
		return fmt.Errorf("alert send: %w", err)
	}
	return nil
}

// parseSessionKey parses "telegram:12345" or "telegram:12345:7"
// into chatID and threadID. Returns error if the key is malformed.
func parseSessionKey(sessionKey string) (chatID, threadID int64, err error) {
	parts := strings.Split(sessionKey, ":")
	if len(parts) < 2 || len(parts) > 3 {
		return 0, 0, fmt.Errorf("invalid session key format: %s", sessionKey)
	}
	if parts[0] != chanTelegram {
		return 0, 0, fmt.Errorf("unsupported channel in session key: %s", parts[0])
	}

	chatID, err = strconv.ParseInt(parts[1], 10, 64)
	if err != nil {
		return 0, 0, fmt.Errorf("invalid chat ID: %w", err)
	}

	if len(parts) == 3 {
		threadID, err = strconv.ParseInt(parts[2], 10, 64)
		if err != nil {
			return 0, 0, fmt.Errorf("invalid thread ID: %w", err)
		}
	}

	return chatID, threadID, nil
}

// resolveEmailSubject builds the email subject line from the payload.
func resolveEmailSubject(p cron.Payload) string {
	if p.Subject != "" {
		now := time.Now()
		dateStr := fmt.Sprintf("%s %d, %d", now.Format("January"), now.Day(), now.Year())
		return strings.ReplaceAll(p.Subject, "{{DATE}}", dateStr)
	}
	return "Gobot Strategic Briefing"
}
