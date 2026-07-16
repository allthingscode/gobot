package app

import (
	"context"
	"fmt"
	"strings"
	"sync"
	"time"

	"github.com/allthingscode/gobot/internal/agent"
	"github.com/allthingscode/gobot/internal/bot"
	"github.com/allthingscode/gobot/internal/integrations/google"
	"github.com/allthingscode/gobot/internal/observability"
	"github.com/allthingscode/gobot/internal/provider"
	"github.com/allthingscode/gobot/internal/reporter"
	"golang.org/x/sync/errgroup"
)

type SendEmailTool struct {
	secretsRoot string
	storageRoot string
	userEmail   string
	registry    *ToolRegistry // C-184: idempotency
	tracer      *observability.DispatchTracer
	tmgr        *reporter.TemplateManager
}

const sendEmailToolName = "send_email"

type gmailService interface {
	SearchMessages(ctx context.Context, query string, maxResults int) ([]google.MessageSummary, error)
	GetMessage(ctx context.Context, id string) (*google.Message, error)
}

type gmailServiceFactory func(ctx context.Context, secretsRoot string) (gmailService, error)

func newGoogleGmailService(ctx context.Context, secretsRoot string) (gmailService, error) {
	svc, err := google.NewService(ctx, secretsRoot)
	if err != nil {
		return nil, err //nolint:wrapcheck // preserve existing Execute-level auth error text
	}
	return svc, nil
}

// newSendEmailTool returns a SendEmailTool that loads OAuth credentials from
// secretsRoot/token.json and always sends to userEmail.
func newSendEmailTool(secretsRoot, storageRoot, userEmail string, registry *ToolRegistry, tracer *observability.DispatchTracer, tmgr *reporter.TemplateManager) *SendEmailTool {
	return &SendEmailTool{
		secretsRoot: secretsRoot,
		storageRoot: storageRoot,
		userEmail:   userEmail,
		registry:    registry,
		tracer:      tracer,
		tmgr:        tmgr,
	}
}

func buildEmailContent(tmgr *reporter.TemplateManager, subject, body string) google.EmailContent {
	if tmgr == nil {
		return google.EmailContent{Subject: subject, Plain: body}
	}
	wrapped := tmgr.Wrap(body)
	if wrapped == body {
		return google.EmailContent{Subject: subject, Plain: body}
	}
	return google.EmailContent{
		Subject: subject,
		Plain:   reporter.StripHTML(wrapped),
		HTML:    wrapped,
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

	// B-059: Enforce deterministic ID for cron jobs if none provided.
	// This prevents duplicate sends within the same day for the same job/recipient.
	if executionID == "" && bot.IsCronSession(sessionKey) {
		executionID = fmt.Sprintf("scheduled_email_auto_%s", time.Now().Format("2006-01-02"))
	}

	if result, hit := checkIdempotency(s.registry, sendEmailToolName, sessionKey, executionID); hit {
		return result, nil
	}

	svc, err := google.NewService(ctx, s.secretsRoot)
	if err != nil {
		return "", fmt.Errorf("send_email: auth: %w", err)
	}

	content := buildEmailContent(s.tmgr, subject, body)

	if s.tracer != nil {
		err = s.tracer.TraceGoogleCall(ctx, "gmail", "Send", func(ctx context.Context) error {
			return svc.Send(ctx, s.userEmail, content)
		})
	} else {
		err = svc.Send(ctx, s.userEmail, content)
	}
	if err != nil {
		fallbackMsg := reporter.FallbackNotify(s.storageRoot, subject, body, s.userEmail, err.Error())
		return fallbackMsg, nil
	}

	result := fmt.Sprintf("Email sent to %s: %s", s.userEmail, subject)
	storeIdempotency(s.registry, sendEmailToolName, sessionKey, executionID, result)

	return result, nil
}

// -- SearchGmailTool -----------------------------------------------------------

const searchGmailToolName = "search_gmail"

type SearchGmailTool struct {
	secretsRoot    string
	tracer         *observability.DispatchTracer
	serviceFactory gmailServiceFactory
}

func newSearchGmailTool(secretsRoot string, tracer *observability.DispatchTracer) *SearchGmailTool {
	return &SearchGmailTool{secretsRoot: secretsRoot, tracer: tracer, serviceFactory: newGoogleGmailService}
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

	maxResults := s.parseMaxResults(args)

	svc, err := s.serviceFactory(ctx, s.secretsRoot)
	if err != nil {
		return "", fmt.Errorf("search_gmail: auth: %w", err)
	}

	summaries, err := s.searchMessages(ctx, svc, query, maxResults)
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

	return s.formatResults(summaries, messages), nil
}

func (s *SearchGmailTool) parseMaxResults(args map[string]any) int {
	maxResults := 5
	if v, ok := args["max_results"]; ok {
		if n, ok := v.(float64); ok {
			maxResults = int(n)
		}
	}
	return maxResults
}

func (s *SearchGmailTool) searchMessages(ctx context.Context, svc gmailService, query string, maxResults int) ([]google.MessageSummary, error) {
	var summaries []google.MessageSummary
	var err error
	if s.tracer != nil {
		err = s.tracer.TraceGoogleCall(ctx, "gmail", "SearchMessages", func(ctx context.Context) error {
			var err2 error
			summaries, err2 = svc.SearchMessages(ctx, query, maxResults)
			if err2 != nil {
				return fmt.Errorf("search messages: %w", err2)
			}
			return nil
		})
	} else {
		var err2 error
		summaries, err2 = svc.SearchMessages(ctx, query, maxResults)
		if err2 != nil {
			err = fmt.Errorf("search messages: %w", err2)
		}
	}
	return summaries, err
}

func (s *SearchGmailTool) formatResults(summaries []google.MessageSummary, messages []*google.Message) string {
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

	return sb.String()
}

func (s *SearchGmailTool) fetchDetails(ctx context.Context, svc gmailService, summaries []google.MessageSummary) ([]*google.Message, error) {
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
	secretsRoot    string
	tracer         *observability.DispatchTracer
	serviceFactory gmailServiceFactory
}

func newReadGmailTool(secretsRoot string, tracer *observability.DispatchTracer) *ReadGmailTool {
	return &ReadGmailTool{secretsRoot: secretsRoot, tracer: tracer, serviceFactory: newGoogleGmailService}
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

	svc, err := s.serviceFactory(ctx, s.secretsRoot)
	if err != nil {
		return "", fmt.Errorf("read_gmail: auth: %w", err)
	}

	var msg *google.Message
	if s.tracer != nil {
		err = s.tracer.TraceGoogleCall(ctx, "gmail", "GetMessage", func(ctx context.Context) error {
			var err2 error
			msg, err2 = svc.GetMessage(ctx, msgID)
			if err2 != nil {
				return fmt.Errorf("get message: %w", err2)
			}
			return nil
		})
	} else {
		var err2 error
		msg, err2 = svc.GetMessage(ctx, msgID)
		if err2 != nil {
			err = fmt.Errorf("get message: %w", err2)
		}
	}
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
