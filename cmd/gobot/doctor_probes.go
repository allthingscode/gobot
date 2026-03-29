package main

import (
	"context"
	"path/filepath"
	"time"

	"github.com/mymmrac/telego"
	"google.golang.org/genai"

	"github.com/allthingscode/gobot/internal/doctor"
	"github.com/allthingscode/gobot/internal/gmail"
)

// liveProbes returns doctor.Probes backed by real Telegram and Gemini API calls.
// Used by cmdDoctor to validate live connectivity.
func liveProbes() *doctor.Probes {
	return &doctor.Probes{
		ProbeTelegram: func(token string) (string, error) {
			client, err := telego.NewBot(token)
			if err != nil {
				return "", err
			}
			self, err := client.GetMe(context.Background())
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
			_, err = client.Models.GenerateContent(ctx, "gemini-2.0-flash",
				[]*genai.Content{{Parts: []*genai.Part{{Text: "ping"}}}},
				nil,
			)
			return err
		},
		ProbeGmail: func(gmailSecretsPath string) error {
			// gmailSecretsPath is the directory containing token.json.
			// gmail.NewService expects the directory path directly.
			tokenDir := filepath.Dir(filepath.Join(gmailSecretsPath, "token.json"))
			_, err := gmail.NewService(tokenDir)
			return err
		},
	}
}
