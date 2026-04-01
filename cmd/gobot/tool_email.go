package main

import (
	"context"
	"fmt"

	"github.com/allthingscode/gobot/internal/gmail"
	"github.com/allthingscode/gobot/internal/provider"
)

type SendEmailTool struct {
	secretsRoot string
	userEmail   string
}

// newSendEmailTool returns a SendEmailTool that loads OAuth credentials from
// secretsRoot/token.json and always sends to userEmail.
func newSendEmailTool(secretsRoot, userEmail string) *SendEmailTool {
	return &SendEmailTool{secretsRoot: secretsRoot, userEmail: userEmail}
}

func (s *SendEmailTool) Name() string { return sendEmailToolName }

func (s *SendEmailTool) Declaration() provider.ToolDeclaration {
	return provider.ToolDeclaration{
		Name:        sendEmailToolName,
		Description: "Send an email via Gmail. The recipient is fixed to the configured user address; only subject and body are required.",
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

	svc, err := gmail.NewService(s.secretsRoot)
	if err != nil {
		return "", fmt.Errorf("send_email: auth: %w", err)
	}

	if err := svc.Send(ctx, s.userEmail, subject, body); err != nil {
		return "", fmt.Errorf("send_email: %w", err)
	}

	return fmt.Sprintf("Email sent to %s: %s", s.userEmail, subject), nil
}
