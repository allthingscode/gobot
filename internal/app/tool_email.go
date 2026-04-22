package app

import (
	"context"
	"fmt"
	"log/slog"
	"strings"
	"sync"

	"github.com/allthingscode/gobot/internal/agent"
	"github.com/allthingscode/gobot/internal/integrations/google"
	"github.com/allthingscode/gobot/internal/provider"
	"github.com/allthingscode/gobot/internal/reporter"
	"golang.org/x/sync/errgroup"
)

type SendEmailTool struct {
	secretsRoot string
	storageRoot string
	userEmail   string
	registry    *ToolRegistry // C-184: idempotency
}

const sendEmailToolName = "send_email"

// newSendEmailTool returns a SendEmailTool that loads OAuth credentials from
// secretsRoot/token.json and always sends to userEmail.
func newSendEmailTool(secretsRoot, storageRoot, userEmail string, registry *ToolRegistry) *SendEmailTool {
	return &SendEmailTool{
		secretsRoot: secretsRoot,
		storageRoot: storageRoot,
		userEmail:   userEmail,
		registry:    registry,
	}
}

type sendEmailArgs struct {
	Subject     string `json:"subject" schema:"Email subject line."`
	Body        string `json:"body" schema:"Email body. Use HTML for best results: <h2> for sections, <p> for paragraphs, <ul>/<li> for lists. Plain text is also accepted."`
	ExecutionID string `json:"execution_id,omitempty" schema:"Optional unique ID for this execution to ensure idempotency across session resumes."`
}

func (s *SendEmailTool) Name() string { return sendEmailToolName }

func (s *SendEmailTool) Declaration() provider.ToolDeclaration {
	return provider.ToolDeclaration{
		Name:          sendEmailToolName,
		Description:   "Send an email via google. The recipient is fixed to the configured user address; only subject and body are required.",
		SideEffecting: true,
		Parameters:    agent.DeriveSchema(sendEmailArgs{}),
	}
}

// Execute sends an email to the hardcoded userEmail using args["subject"] and
// args["body"]. The "to" address is never read from args. Returns a
// confirmation string on success.
func (s *SendEmailTool) Execute(ctx context.Context, sessionKey, userID string, args map[string]any) (string, error) {
	subject, _ := args["subject"].(string)
	body, _ := args["body"].(string)

	if subject == "" {
		return "", fmt.Errorf("send_email: subject is required")
	}
	if body == "" {
		return "", fmt.Errorf("send_email: body is required")
	}

	executionID, _ := args["execution_id"].(string)
	if result, hit := s.checkIdempotency(sessionKey, executionID); hit {
		return result, nil
	}

	svc, err := google.NewService(ctx, s.secretsRoot)
	if err != nil {
		return "", fmt.Errorf("send_email: auth: %w", err)
	}

	if err := svc.Send(ctx, s.userEmail, subject, body); err != nil {
		fallbackMsg := reporter.FallbackNotify(s.storageRoot, subject, body, s.userEmail, err.Error())
		return fallbackMsg, nil
	}

	result := fmt.Sprintf("Email sent to %s: %s", s.userEmail, subject)
	s.storeIdempotency(sessionKey, executionID, result)

	return result, nil
}

func (s *SendEmailTool) checkIdempotency(sessionKey, executionID string) (string, bool) {
	if executionID != "" && s.registry != nil {
		if result, ok := s.registry.Check(sessionKey, executionID); ok {
			slog.Info("send_email: idempotency hit", "session", sessionKey, "execution_id", executionID)
			return result, true
		}
	}
	return "", false
}

func (s *SendEmailTool) storeIdempotency(sessionKey, executionID, result string) {
	if executionID != "" && s.registry != nil {
		if storeErr := s.registry.Store(sessionKey, executionID, result); storeErr != nil {
			slog.Warn("send_email: failed to store idempotency result", "err", storeErr)
		}
	}
}

// -- SearchGmailTool -----------------------------------------------------------

const searchGmailToolName = "search_gmail"

type SearchGmailTool struct {
	secretsRoot string
}

func newSearchGmailTool(secretsRoot string) *SearchGmailTool {
	return &SearchGmailTool{secretsRoot: secretsRoot}
}

type searchGmailArgs struct {
	Query      string `json:"query" schema:"Gmail search query (e.g. 'from:example.com', 'is:unread', 'subject:report')."`
	MaxResults int    `json:"max_results,omitempty" schema:"Maximum number of results to return. Defaults to 5."`
}

func (s *SearchGmailTool) Name() string { return searchGmailToolName }

func (s *SearchGmailTool) Declaration() provider.ToolDeclaration {
	return provider.ToolDeclaration{
		Name:        searchGmailToolName,
		Description: "Search the user's Gmail inbox for messages matching a query. Returns a list of message IDs, subjects, and snippets.",
		Parameters:  agent.DeriveSchema(searchGmailArgs{}),
	}
}

func (s *SearchGmailTool) Execute(ctx context.Context, _, _ string, args map[string]any) (string, error) {
	query, _ := args["query"].(string)
	if strings.TrimSpace(query) == "" {
		return "", fmt.Errorf("search_gmail: query is required")
	}

	maxResults := 5
	if v, ok := args["max_results"]; ok {
		if n, ok := v.(float64); ok {
			maxResults = int(n)
		}
	}

	svc, err := google.NewService(ctx, s.secretsRoot)
	if err != nil {
		return "", fmt.Errorf("search_gmail: auth: %w", err)
	}

	summaries, err := svc.SearchMessages(ctx, query, maxResults)
	if err != nil {
		return "", fmt.Errorf("search_gmail: %w", err)
	}

	if len(summaries) == 0 {
		return "No messages found matching the query.", nil
	}

	messages, err := s.fetchDetails(ctx, svc, summaries)
	if err != nil {
		return "", err
	}

	var sb strings.Builder
	fmt.Fprintf(&sb, "Found %d messages:\n\n", len(summaries))
	for i, msg := range messages {
		if msg == nil {
			fmt.Fprintf(&sb, "- ID: %s (Error loading details)\n", summaries[i].ID)
			continue
		}
		subject := msg.GetHeader("Subject")
		from := msg.GetHeader("From")
		fmt.Fprintf(&sb, "- **ID**: %s\n", msg.ID)
		fmt.Fprintf(&sb, "  **From**: %s\n", from)
		fmt.Fprintf(&sb, "  **Subject**: %s\n", subject)
		fmt.Fprintf(&sb, "  **Snippet**: %s\n\n", msg.Snippet)
	}

	return sb.String(), nil
}

func (s *SearchGmailTool) fetchDetails(ctx context.Context, svc *google.Service, summaries []google.MessageSummary) ([]*google.Message, error) {
	messages := make([]*google.Message, len(summaries))
	g, gctx := errgroup.WithContext(ctx)
	var mu sync.Mutex

	for i, sum := range summaries {
		i, sum := i, sum // capture
		g.Go(func() error {
			msg, err := svc.GetMessage(gctx, sum.ID)
			if err != nil {
				// We intentionally ignore errors for individual messages to ensure
				// the tool returns what it *did* find rather than failing completely.
				return nil //nolint:nilerr // explanation: skip individual message fetch errors
			}
			mu.Lock()
			messages[i] = msg
			mu.Unlock()
			return nil
		})
	}

	if err := g.Wait(); err != nil {
		return nil, fmt.Errorf("search_gmail: fetch details: %w", err)
	}
	return messages, nil
}

// -- ReadGmailTool ------------------------------------------------------------

const readGmailToolName = "read_gmail"

type ReadGmailTool struct {
	secretsRoot string
}

func newReadGmailTool(secretsRoot string) *ReadGmailTool {
	return &ReadGmailTool{secretsRoot: secretsRoot}
}

func (s *ReadGmailTool) Name() string { return readGmailToolName }

type readGmailArgs struct {
	MessageID string `json:"message_id" schema:"The Gmail message ID (obtained from search_gmail)."`
}

func (s *ReadGmailTool) Declaration() provider.ToolDeclaration {
	return provider.ToolDeclaration{
		Name:        readGmailToolName,
		Description: "Read the full content of a specific Gmail message by its ID.",
		Parameters:  agent.DeriveSchema(readGmailArgs{}),
	}
}

func (s *ReadGmailTool) Execute(ctx context.Context, _, _ string, args map[string]any) (string, error) {
	msgID, _ := args["message_id"].(string)
	if msgID == "" {
		return "", fmt.Errorf("read_gmail: message_id is required")
	}

	svc, err := google.NewService(ctx, s.secretsRoot)
	if err != nil {
		return "", fmt.Errorf("read_gmail: auth: %w", err)
	}

	msg, err := svc.GetMessage(ctx, msgID)
	if err != nil {
		return "", fmt.Errorf("read_gmail: %w", err)
	}

	var sb strings.Builder
	fmt.Fprintf(&sb, "### Email Details (ID: %s)\n\n", msg.ID)
	fmt.Fprintf(&sb, "**From**: %s\n", msg.GetHeader("From"))
	fmt.Fprintf(&sb, "**To**: %s\n", msg.GetHeader("To"))
	fmt.Fprintf(&sb, "**Date**: %s\n", msg.GetHeader("Date"))
	fmt.Fprintf(&sb, "**Subject**: %s\n\n", msg.GetHeader("Subject"))
	sb.WriteString("---\n\n")
	sb.WriteString(msg.ExtractBody())
	sb.WriteString("\n\n---")

	return sb.String(), nil
}
