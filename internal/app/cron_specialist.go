package app

import (
	"context"
	"fmt"
	"log/slog"

	"github.com/allthingscode/gobot/internal/bot"
	"github.com/allthingscode/gobot/internal/config"
	"github.com/allthingscode/gobot/internal/cron"
	"github.com/allthingscode/gobot/internal/provider"
)

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

	sessionKey := bot.SessionPrefixCron + p.Agent + ":" + p.ID
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

func (cd *CronDispatcher) dispatchSilent(ctx context.Context, p cron.Payload, to string) error {
	if to == "" {
		slog.Warn("unroutable silent cron job", "to", to)
		return nil
	}
	sessionKey := bot.SessionPrefixCron + to
	slog.Info("dispatching cron job", "session", sessionKey, "silent", true)
	_, err := cd.mgr.Dispatch(ctx, sessionKey, "", "[SILENT] [AUTONOMOUS] "+p.Message)
	if err != nil {
		return fmt.Errorf("dispatch silent: %w", err)
	}
	return nil
}
