//nolint:testpackage // requires unexported gemini provider internals for testing
package provider

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	agentctx "github.com/allthingscode/gobot/internal/context"
	"google.golang.org/genai"
)

func TestGeminiProvider_NameAndModels(t *testing.T) {
	t.Parallel()
	p := NewGeminiProvider(&genai.Client{})
	if p.Name() != "gemini" {
		t.Errorf("got %q, want %q", p.Name(), "gemini")
	}

	models := p.Models()
	if len(models) == 0 {
		t.Fatal("expected models")
	}

	found := false
	for _, m := range models {
		if m.ID == "gemini-2.0-flash" {
			found = true
			if !m.SupportsToolUse {
				t.Error("expected gemini-2.0-flash to support tool use")
			}
		}
	}
	if !found {
		t.Error("expected gemini-2.0-flash in models")
	}
}

type chatTestCase struct {
	name        string
	httpStatus  int
	mockResp    any
	reqModel    string
	reqStr      string
	wantErr     string
	wantTokens  int
	wantContent string
	wantTool    string
}

func setupGeminiMock(t *testing.T, status int, resp any) (*httptest.Server, *genai.Client) {
	t.Helper()
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(status)
		_ = json.NewEncoder(w).Encode(resp)
	}))
	ctx := context.Background()
	client, err := genai.NewClient(ctx, &genai.ClientConfig{
		APIKey: "fake-key",
		HTTPOptions: genai.HTTPOptions{
			BaseURL: ts.URL,
		},
	})
	if err != nil {
		ts.Close()
		t.Fatalf("failed to create client: %v", err)
	}
	return ts, client
}

func validateChatResponse(t *testing.T, resp *ChatResponse, err error, tt chatTestCase) {
	t.Helper()
	if tt.wantErr != "" {
		verifyChatError(t, err, tt.wantErr)
		return
	}

	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	verifyChatSuccess(t, resp, tt)
}

func verifyChatError(t *testing.T, err error, wantErr string) {
	t.Helper()
	if err == nil {
		t.Fatalf("expected error containing %q, got nil", wantErr)
	}
	if !strings.Contains(err.Error(), wantErr) {
		t.Errorf("expected error containing %q, got: %v", wantErr, err)
	}
}

func verifyChatSuccess(t *testing.T, resp *ChatResponse, tt chatTestCase) {
	t.Helper()
	if resp.Usage.TotalTokens != tt.wantTokens {
		t.Errorf("got %d total tokens, want %d", resp.Usage.TotalTokens, tt.wantTokens)
	}

	if tt.wantContent != "" {
		if resp.Message.Content == nil || *resp.Message.Content.Str != tt.wantContent {
			t.Errorf("unexpected content: %v", resp.Message.Content)
		}
	}

	if tt.wantTool != "" {
		if len(resp.Message.ToolCalls) == 0 || resp.Message.ToolCalls[0].Name != tt.wantTool {
			t.Errorf("expected tool %q, got: %v", tt.wantTool, resp.Message.ToolCalls)
		}
	}
}

func TestGeminiProvider_Chat(t *testing.T) {
	t.Parallel()
	tests := []chatTestCase{
		{
			name:       "success with tool call",
			httpStatus: http.StatusOK,
			reqModel:   "gemini-2.0-flash",
			reqStr:     "hello",
			mockResp: genai.GenerateContentResponse{
				Candidates: []*genai.Candidate{
					{
						Content: &genai.Content{
							Parts: []*genai.Part{
								{Text: "hello from gemini"},
								{
									FunctionCall: &genai.FunctionCall{
										Name: "my_tool",
										Args: map[string]any{"arg1": "val1"},
									},
								},
							},
						},
					},
				},
				UsageMetadata: &genai.GenerateContentResponseUsageMetadata{
					PromptTokenCount:     5,
					CandidatesTokenCount: 15,
					TotalTokenCount:      20,
				},
			},
			wantTokens:  20,
			wantContent: "hello from gemini",
			wantTool:    "my_tool",
		},
		{
			name:       "nil candidate response",
			httpStatus: http.StatusOK,
			reqModel:   "gemini-2.0-flash",
			reqStr:     "hello",
			mockResp: genai.GenerateContentResponse{
				Candidates: []*genai.Candidate{}, // empty
			},
			wantErr: "no candidates returned",
		},
		{
			name:       "http error 500",
			httpStatus: http.StatusInternalServerError,
			reqModel:   "gemini-2.0-flash",
			reqStr:     "hello",
			mockResp:   map[string]any{"error": map[string]string{"message": "internal error"}},
			wantErr:    "internal error",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			ts, client := setupGeminiMock(t, tt.httpStatus, tt.mockResp)
			defer ts.Close()

			ctx := context.Background()
			p := NewGeminiProvider(client)
			req := ChatRequest{
				Model: tt.reqModel,
				Messages: []agentctx.StrategicMessage{
					{
						Role:    agentctx.RoleUser,
						Content: &agentctx.MessageContent{Str: &tt.reqStr},
					},
				},
			}

			resp, err := p.Chat(ctx, req)
			validateChatResponse(t, resp, err, tt)
		})
	}
}

func TestGeminiProvider_Helpers(t *testing.T) {
	t.Parallel()
	p := NewGeminiProvider(&genai.Client{})

	t.Run("messagesToContents", func(t *testing.T) {
		t.Parallel()
		str1 := "msg 1"
		messages := []agentctx.StrategicMessage{
			{Role: agentctx.RoleUser, Content: &agentctx.MessageContent{Str: &str1}},
			{Role: agentctx.RoleAssistant, Content: &agentctx.MessageContent{Str: &str1}},
			{Role: agentctx.RoleTool, Name: func() *string { s := "my_tool"; return &s }(), Content: &agentctx.MessageContent{Str: func() *string { s := `{"res": 1}`; return &s }()}},
		}

		contents := p.messagesToContents(messages)
		if len(contents) != 3 {
			t.Fatalf("got %d contents, want 3", len(contents))
		}
		if contents[0].Role != "user" || contents[1].Role != "model" || contents[2].Role != "user" {
			t.Errorf("roles mapped incorrectly")
		}
	})

	t.Run("buildConfig", func(t *testing.T) {
		t.Parallel()
		req := ChatRequest{
			SystemInstruction: "sys",
			MaxTokens:         100,
			Temperature:       0.5,
			Tools: []ToolDeclaration{
				{Name: "tool1", Parameters: map[string]any{"type": "object"}},
			},
		}

		cfg := p.buildConfig(req)
		if cfg.SystemInstruction.Parts[0].Text != "sys" {
			t.Errorf("unexpected sys instruction")
		}
		if cfg.MaxOutputTokens != 100 {
			t.Errorf("got max tokens %d", cfg.MaxOutputTokens)
		}
		if cfg.Tools[0].FunctionDeclarations[0].Name != "tool1" {
			t.Errorf("unexpected tool name")
		}
	})
}
