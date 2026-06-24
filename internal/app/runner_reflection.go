package app

import (
	"context"
	"log/slog"

	agentctx "github.com/allthingscode/gobot/internal/context"
	"github.com/allthingscode/gobot/internal/reflection"
)

func (r *AgentRunner) generateReflectionRubric(ctx context.Context, sessionKey, userText string) map[string]any {
	if !r.EnableReflection || userText == "" {
		return nil
	}
	planPrompt := reflection.GenerateRubricPrompt(userText)
	planStr, planErr := r.RunText(ctx, sessionKey, planPrompt, "")
	if planErr != nil {
		return nil
	}
	parsed, ok := reflection.ParseJSONResponse(planStr)
	if !ok {
		return nil
	}
	slog.Debug("runner: planning rubric generated", "session", sessionKey)
	return parsed
}

func (r *AgentRunner) performReflectionAudit(ctx context.Context, sessionKey, userText string, rubric map[string]any, text string, reflectionRounds *int) (agentctx.StrategicMessage, bool) {
	criticPrompt := reflection.GenerateCriticPrompt(userText, rubric, text)
	criticStr, criticErr := r.RunText(ctx, sessionKey, criticPrompt, "")
	if criticErr != nil {
		return agentctx.StrategicMessage{}, true
	}

	report, ok := reflection.ParseJSONResponse(criticStr)
	if !ok {
		return agentctx.StrategicMessage{}, true
	}

	score := reflection.CalculateTotalScore(report, rubric)
	threshold := 0.7
	if t, ok := rubric["success_threshold"].(float64); ok {
		threshold = t
	}

	if score < threshold {
		*reflectionRounds++
		correction := BuildCorrectionMessage(report)
		slog.Info("runner: reflection backtrack triggered",
			"session", sessionKey,
			"score", score,
			"threshold", threshold,
			"round", *reflectionRounds,
		)
		return agentctx.StrategicMessage{
			Role:    agentctx.RoleUser,
			Content: &agentctx.MessageContent{Str: &correction},
		}, false
	}

	*reflectionRounds = 0 // Reset on success
	slog.Debug("runner: reflection passed", "session", sessionKey, "score", score)
	return agentctx.StrategicMessage{}, true
}

func (r *AgentRunner) handleTerminalResponse(ctx context.Context, sessionKey, userText string, rubric map[string]any, respMsg agentctx.StrategicMessage, messages *[]agentctx.StrategicMessage, reflectionRounds *int) (string, bool) {
	text := ExtractText(respMsg)
	if r.EnableReflection && rubric != nil {
		if *reflectionRounds >= r.MaxReflectionRounds {
			if r.MaxReflectionRounds > 0 {
				slog.Warn("reflection: all audit rounds failed, skipping revision",
					"session", sessionKey,
					"rounds", r.MaxReflectionRounds,
				)
			}
			return text, true
		}

		if msg, ok := r.performReflectionAudit(ctx, sessionKey, userText, rubric, text, reflectionRounds); !ok {
			*messages = append(*messages, msg)
			return "", false
		}
	}
	return text, true
}
