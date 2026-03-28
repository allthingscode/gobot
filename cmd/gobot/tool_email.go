package main

import (
	"context"
	"fmt"

	"google.golang.org/genai"

	"github.com/allthingscode/gobot/internal/gmail"
)

const sendEmailToolName = "send_email"

// SendEmailTool implements Tool and sends an email via Gmail.
// For security, the recipient address is fixed at construction time and is
// never accepted from the model — Gemini may only supply subject and body.
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

func (s *SendEmailTool) Declaration() *genai.FunctionDeclaration {
	return &genai.FunctionDeclaration{
		Name:        sendEmailToolName,
		Description: "Send an email via Gmail. The recipient is fixed to the configured user address; only subject and body are required.",
		Parameters: &genai.Schema{
			Type: genai.TypeObject,
			Properties: map[string]*genai.Schema{
				"subject": {
					Type:        genai.TypeString,
					Description: "Email subject line.",
				},
				"body": {
					Type:        genai.TypeString,
					Description: "Email body as plain text.",
				},
			},
			Required: []string{"subject", "body"},
		},
	}
}

// Execute sends an email to the hardcoded userEmail using args["subject"] and
// args["body"]. The "to" address is never read from args. Returns a
// confirmation string on success.
func (s *SendEmailTool) Execute(_ context.Context, _ string, args map[string]any) (string, error) {
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

	if err := svc.Send(s.userEmail, subject, body); err != nil {
		return "", fmt.Errorf("send_email: %w", err)
	}

	return fmt.Sprintf("Email sent to %s: %s", s.userEmail, subject), nil
}
