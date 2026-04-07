package main

import (
	"context"
	"fmt"
	"strings"

	"github.com/allthingscode/gobot/internal/integrations/google"
	"github.com/allthingscode/gobot/internal/provider"
	"github.com/allthingscode/gobot/internal/reporter"
)

type SendEmailTool struct {
	secretsRoot string
	storageRoot string
	userEmail   string
}

// newSendEmailTool returns a SendEmailTool that loads OAuth credentials from
// secretsRoot/token.json and always sends to userEmail.
func newSendEmailTool(secretsRoot, storageRoot, userEmail string) *SendEmailTool {
	return &SendEmailTool{secretsRoot: secretsRoot, storageRoot: storageRoot, userEmail: userEmail}
}

func (s *SendEmailTool) Name() string { return sendEmailToolName }

func (s *SendEmailTool) Declaration() provider.ToolDeclaration {
	return provider.ToolDeclaration{
		Name:        sendEmailToolName,
		Description: "Send an email via google. The recipient is fixed to the configured user address; only subject and body are required.",
		Parameters: map[string]any{
			"type": "object",
			"properties": map[string]any{
				"subject": map[string]any{
					"type":        "string",
					"description": "Email subject line.",
				},
				"body": map[string]any{
					"type":        "string",
					"description": "Email body. Use HTML for best results: <h2> for sections, <p> for paragraphs, <ul>/<li> for lists. Plain text is also accepted.",
				},
			},
			"required": []string{"subject", "body"},
		},
	}
}

// Execute sends an email to the hardcoded userEmail using args["subject"] and
// args["body"]. The "to" address is never read from args. Returns a
// confirmation string on success.
func (s *SendEmailTool) Execute(ctx context.Context, _ string, args map[string]any) (string, error) {
	subject, _ := args["subject"].(string)
	body, _ := args["body"].(string)

	if subject == "" {
		return "", fmt.Errorf("send_email: subject is required")
	}
	if body == "" {
		return "", fmt.Errorf("send_email: body is required")
	}

	svc, err := google.NewService(s.secretsRoot)
	if err != nil {
		return "", fmt.Errorf("send_email: auth: %w", err)
	}

	if err := svc.Send(ctx, s.userEmail, subject, body); err != nil {
		fallbackMsg := reporter.FallbackNotify(s.storageRoot, subject, body, s.userEmail, err.Error())
		return fallbackMsg, nil
	}

	return fmt.Sprintf("Email sent to %s: %s", s.userEmail, subject), nil
}

// -- SearchGmailTool -----------------------------------------------------------

const searchGmailToolName = "search_gmail"

type SearchGmailTool struct {
	secretsRoot string
}

func newSearchGmailTool(secretsRoot string) *SearchGmailTool {
	return &SearchGmailTool{secretsRoot: secretsRoot}
}

func (s *SearchGmailTool) Name() string { return searchGmailToolName }

func (s *SearchGmailTool) Declaration() provider.ToolDeclaration {
	return provider.ToolDeclaration{
		Name:        searchGmailToolName,
		Description: "Search the user's Gmail inbox for messages matching a query. Returns a list of message IDs, subjects, and snippets.",
		Parameters: map[string]any{
			"type": "object",
			"properties": map[string]any{
				"query": map[string]any{
					"type":        "string",
					"description": "Gmail search query (e.g. 'from:example.com', 'is:unread', 'subject:report').",
				},
				"max_results": map[string]any{
					"type":        "integer",
					"description": "Maximum number of results to return. Defaults to 5.",
				},
			},
			"required": []string{"query"},
		},
	}
}

func (s *SearchGmailTool) Execute(ctx context.Context, _ string, args map[string]any) (string, error) {
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

	svc, err := google.NewService(s.secretsRoot)
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

	var sb strings.Builder
	sb.WriteString(fmt.Sprintf("Found %d messages:\n\n", len(summaries)))
	for _, sum := range summaries {
		msg, err := svc.GetMessage(ctx, sum.ID)
		if err != nil {
			sb.WriteString(fmt.Sprintf("- ID: %s (Error loading details)\n", sum.ID))
			continue
		}
		subject := msg.GetHeader("Subject")
		from := msg.GetHeader("From")
		sb.WriteString(fmt.Sprintf("- **ID**: %s\n", msg.ID))
		sb.WriteString(fmt.Sprintf("  **From**: %s\n", from))
		sb.WriteString(fmt.Sprintf("  **Subject**: %s\n", subject))
		sb.WriteString(fmt.Sprintf("  **Snippet**: %s\n\n", msg.Snippet))
	}

	return sb.String(), nil
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

func (s *ReadGmailTool) Declaration() provider.ToolDeclaration {
	return provider.ToolDeclaration{
		Name:        readGmailToolName,
		Description: "Read the full content of a specific Gmail message by its ID.",
		Parameters: map[string]any{
			"type": "object",
			"properties": map[string]any{
				"message_id": map[string]any{
					"type":        "string",
					"description": "The Gmail message ID (obtained from search_gmail).",
				},
			},
			"required": []string{"message_id"},
		},
	}
}

func (s *ReadGmailTool) Execute(ctx context.Context, _ string, args map[string]any) (string, error) {
	msgID, _ := args["message_id"].(string)
	if msgID == "" {
		return "", fmt.Errorf("read_gmail: message_id is required")
	}

	svc, err := google.NewService(s.secretsRoot)
	if err != nil {
		return "", fmt.Errorf("read_gmail: auth: %w", err)
	}

	msg, err := svc.GetMessage(ctx, msgID)
	if err != nil {
		return "", fmt.Errorf("read_gmail: %w", err)
	}

	var sb strings.Builder
	sb.WriteString(fmt.Sprintf("### Email Details (ID: %s)\n\n", msg.ID))
	sb.WriteString(fmt.Sprintf("**From**: %s\n", msg.GetHeader("From")))
	sb.WriteString(fmt.Sprintf("**To**: %s\n", msg.GetHeader("To")))
	sb.WriteString(fmt.Sprintf("**Date**: %s\n", msg.GetHeader("Date")))
	sb.WriteString(fmt.Sprintf("**Subject**: %s\n\n", msg.GetHeader("Subject")))
	sb.WriteString("---\n\n")
	sb.WriteString(msg.ExtractBody())
	sb.WriteString("\n\n---")

	return sb.String(), nil
}
