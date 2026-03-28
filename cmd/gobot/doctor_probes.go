package main

import (
	"context"
	"time"

	tgbotapi "github.com/go-telegram-bot-api/telegram-bot-api/v5"
	"google.golang.org/genai"

	"github.com/allthingscode/gobot/internal/doctor"
)

// liveProbes returns doctor.Probes backed by real Telegram and Gemini API calls.
// Used by cmdDoctor to validate live connectivity.
func liveProbes() *doctor.Probes {
	return &doctor.Probes{
		ProbeTelegram: func(token string) (string, error) {
			client, err := tgbotapi.NewBotAPI(token)
			if err != nil {
				return "", err
			}
			return "@" + client.Self.UserName, nil
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
	}
}
