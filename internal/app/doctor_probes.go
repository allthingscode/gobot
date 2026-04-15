package app

import (
	"context"
	"path/filepath"
	"time"

	"github.com/mymmrac/telego"
	"google.golang.org/genai"

	"github.com/allthingscode/gobot/internal/doctor"
	"github.com/allthingscode/gobot/internal/infra"
	"github.com/allthingscode/gobot/internal/integrations/google"
)

// LiveProbesList returns doctor.Probes backed by real Telegram and Gemini API calls.
// Used by cmdDoctor to validate live connectivity.
func LiveProbesList() *doctor.Probes {
	return &doctor.Probes{
		ProbeTelegram: func(token string) (string, error) {
			client, err := telego.NewBot(token)
			if err != nil {
				return "", err
			}

			ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
			defer cancel()

			self, err := client.GetMe(ctx)
			if err != nil {
				return "", err
			}
			return "@" + self.Username, nil
		},
		ProbeGemini: func(apiKey string) error {
			ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
			defer cancel()

			client, err := genai.NewClient(ctx, &genai.ClientConfig{
				APIKey:  apiKey,
				Backend: genai.BackendGeminiAPI,
			})
			if err != nil {
				return err
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
			return err
		},
		ProbeGmail: func(gmailSecretsPath string) error {
			// gmailSecretsPath is the directory containing token.json.
			// google.NewService expects the directory path directly.
			tokenDir := filepath.Dir(filepath.Join(gmailSecretsPath, "token.json"))
			_, err := google.NewService(tokenDir)
			return err
		},
	}
}
