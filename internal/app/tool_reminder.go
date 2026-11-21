package app

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"time"

	"github.com/allthingscode/gobot/internal/agent"
	"github.com/allthingscode/gobot/internal/provider"
	"github.com/allthingscode/gobot/internal/reminder"
)

const (
	createReminderName = "create_reminder"
	listRemindersName  = "list_reminders"
	cancelReminderName = "cancel_reminder"
)

type reminderTool struct {
	name  string
	store *reminder.Store
	auth  reminderAuthorization
}

type createReminderArgs struct {
	Text string `json:"text" schema:"Exact plain text to deliver (1-4096 UTF-8 bytes). Stored text will never be interpreted or executed."`
	Time string `json:"time" schema:"Resolved future RFC3339 instant with explicit offset, e.g. 2027-01-02T09:00:00-06:00 or Z. Ask for clarification for missing timezone, ambiguous/nonexistent local times or unresolved expressions; never guess."`
}

type cancelReminderArgs struct {
	ID string `json:"id" schema:"Stable reminder ID returned by create_reminder or list_reminders."`
}

func (t *reminderTool) Name() string { return t.name }

func (t *reminderTool) Declaration() provider.ToolDeclaration {
	d := provider.ToolDeclaration{Name: t.name}
	switch t.name {
	case createReminderName:
		d.Description = "Save a one-time Telegram reminder for the current authenticated sender and original chat/topic. Clarify unresolved or ambiguous time before calling. Confirm only the returned saved ID and offset time."
		d.Parameters, d.SideEffecting = agent.DeriveSchema(createReminderArgs{}), true
	case cancelReminderName:
		d.Description = "Cancel one of your own pending Telegram reminders by ID. Delivery already in progress cannot be prevented."
		d.Parameters, d.SideEffecting = agent.DeriveSchema(cancelReminderArgs{}), true
	case listRemindersName:
		d.Description = "List your Telegram reminders in this chat, including delivery state, attempts, failed status and saved offset time."
		d.Parameters = agent.DeriveSchema(struct{}{})
	}
	return d
}

func (t *reminderTool) Execute(ctx context.Context, session, userID string, args map[string]any) (string, error) {
	c, err := reminderIdentity(ctx, session, userID)
	if err != nil {
		return "", err
	}
	lookupCtx, cancel := context.WithTimeout(ctx, 5*time.Second)
	allowed, err := t.auth.allowed(lookupCtx, c.owner)
	cancel()
	if err != nil || !allowed {
		return "", errors.New("reminder: authorization failed")
	}
	// Owner and destination are deliberately absent from the argument schema.
	// Reject extra arguments too, rather than silently implying a requested
	// destination or owner was honored.
	return t.executeOwned(ctx, c, args)
}

func (t *reminderTool) executeOwned(ctx context.Context, c *reminderCapability, args map[string]any) (string, error) {
	switch t.name {
	case createReminderName:
		if err := reminderArgumentKeys(args, "text", "time"); err != nil {
			return "", err
		}
		text, _ := args["text"].(string)
		value, _ := args["time"].(string)
		now := time.Now()
		due, err := reminder.ParseTime(value, now)
		if err != nil {
			return "", fmt.Errorf("create reminder time: %w", err)
		}
		r, err := t.store.Create(ctx, c.owner, c.topicID, text, due, now)
		if err != nil {
			return "", fmt.Errorf("create reminder: %w", err)
		}
		return reminderJSON(r)
	case listRemindersName:
		if err := reminderArgumentKeys(args); err != nil {
			return "", err
		}
		rows, err := t.store.List(ctx, c.owner)
		if err != nil {
			return "", fmt.Errorf("list reminders: %w", err)
		}
		return reminderJSON(rows)
	case cancelReminderName:
		return t.cancel(ctx, c, args)
	default:
		return "", errors.New("reminder: unknown action")
	}
}

func (t *reminderTool) cancel(ctx context.Context, c *reminderCapability, args map[string]any) (string, error) {
	if err := reminderArgumentKeys(args, "id"); err != nil {
		return "", err
	}
	id, _ := args["id"].(string)
	if id == "" {
		return "", errors.New("reminder: ID required")
	}
	state, err := t.store.Cancel(ctx, c.owner, id, time.Now())
	if err != nil {
		return "", fmt.Errorf("cancel reminder: %w", err)
	}
	if state == reminder.Dispatching {
		return "Delivery in progress; cancellation cannot prevent this send.", nil
	}
	return reminderJSON(struct {
		ID    string         `json:"id"`
		State reminder.State `json:"state"`
	}{id, state})
}

func reminderArgumentKeys(args map[string]any, keys ...string) error {
	for key := range args {
		found := false
		for _, allowed := range keys {
			found = found || key == allowed
		}
		if !found {
			return errors.New("reminder: unexpected argument; owner and destination come only from Telegram")
		}
	}
	return nil
}

func reminderJSON(value any) (string, error) {
	data, err := json.Marshal(value)
	if err != nil {
		return "", fmt.Errorf("reminder encode result: %w", err)
	}
	return string(data), nil
}
