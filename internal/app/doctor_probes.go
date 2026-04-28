package app

import (
	"context"
	"fmt"
	"strings"
	"path/filepath"
	"time"

	"github.com/mymmrac/telego"
	"google.golang.org/genai"

	"github.com/allthingscode/gobot/internal/doctor"
	"github.com/allthingscode/gobot/internal/infra"
	"github.com/allthingscode/gobot/internal/integrations/google"
	"github.com/allthingscode/gobot/internal/resilience"
)

// LiveProbesList returns doctor.Probes backed by real Telegram and Gemini API calls.
// Used by cmdDoctor to validate live connectivity.
func LiveProbesList() *doctor.Probes {
	return &doctor.Probes{
		ProbeTelegram: func(token string) (string, error) {
			client, err := telego.NewBot(token)
			if err != nil {
				return "", fmt.Errorf("new bot: %w", err)
			}

			ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
			defer cancel()

			self, err := client.GetMe(ctx)
			if err != nil {
				return "", fmt.Errorf("get bot info: %w", err)
			}
			return "@" + self.Username, nil
		},
		ProbeGemini: func(apiKey string) error {
			retryErr := resilience.Do(context.Background(), resilience.RetryConfig{
				MaxAttempts:  3,
				InitialDelay: 500 * time.Millisecond,
				MaxDelay:     2 * time.Second,
				Multiplier:   2.0,
				JitterFactor: 0.2,
			}, shouldRetryGeminiProbe, func() error {
				ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
				defer cancel()

				client, err := genai.NewClient(ctx, &genai.ClientConfig{
					APIKey:  apiKey,
					Backend: genai.BackendGeminiAPI,
				})
				if err != nil {
					return fmt.Errorf("new genai client: %w", err)
				}

				// Register for cleanup
				res := infra.NewClosableResource("doctor:gemini", func() error {
					// genai.Client doesn't have Close, but we document the pattern
					return nil
				})
				defer func() { _ = res.Close() }()

				_, err = client.Models.GenerateContent(ctx, "gemini-2.0-flash",
					[]*genai.Content{{Parts: []*genai.Part{{Text: "ping"}}}},
					nil,
				)
				if err != nil {
					return fmt.Errorf("generate content: %w", err)
				}
				return nil
			})
			if retryErr != nil {
				return fmt.Errorf("gemini probe retry: %w", retryErr)
			}
			return nil
		},
		ProbeGmail: func(gmailSecretsPath string) error {
			// gmailSecretsPath is the directory containing token.json.
			// google.NewService expects the directory path directly.
			tokenDir := filepath.Dir(filepath.Join(gmailSecretsPath, "token.json"))
			_, err := google.NewService(context.Background(), tokenDir)
			if err != nil {
				return fmt.Errorf("new google service: %w", err)
			}
			return nil
		},
	}
}

func shouldRetryGeminiProbe(err error) bool {
	if err == nil {
		return false
	}
	msg := strings.ToLower(err.Error())
	if strings.Contains(msg, "429") || strings.Contains(msg, "resource_exhausted") {
		return true
	}
	return resilience.IsRetryable(err)
}
