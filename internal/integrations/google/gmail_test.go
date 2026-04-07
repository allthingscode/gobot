package google

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestGmailSearchAndRead(t *testing.T) {
	mux := http.NewServeMux()

	// Mock List/Search
	mux.HandleFunc("/messages", func(w http.ResponseWriter, r *http.Request) {
		q := r.URL.Query().Get("q")
		if q == "empty" {
			_ = json.NewEncoder(w).Encode(map[string]any{"messages": []any{}})
			return
		}
		resp := struct {
			Messages []MessageSummary `json:"messages"`
		}{
			Messages: []MessageSummary{
				{ID: "msg123", ThreadID: "thread123"},
			},
		}
		_ = json.NewEncoder(w).Encode(resp)
	})

	// Mock Get Message
	mux.HandleFunc("/messages/msg123", func(w http.ResponseWriter, _ *http.Request) {
		msg := Message{
			ID:      "msg123",
			Snippet: "Hello world snippet",
			Payload: &Payload{
				Headers: []Header{
					{Name: "Subject", Value: "Test Subject"},
					{Name: "From", Value: "sender@example.com"},
				},
				Body: &Body{
					Data: base64.URLEncoding.EncodeToString([]byte("Full body text")),
				},
			},
		}
		_ = json.NewEncoder(w).Encode(msg)
	})

	server := httptest.NewServer(mux)
	t.Cleanup(server.Close)

	// Setup fake secrets
	tmp := t.TempDir()
	tok := storedToken{
		Token:  "fake-token",
		Expiry: time.Now().Add(1 * time.Hour),
	}
	tokData, _ := json.Marshal(tok)
	_ = os.WriteFile(filepath.Join(tmp, "token.json"), tokData, 0600)

	svc, err := NewService(tmp)
	if err != nil {
		t.Fatalf("NewService failed: %v", err)
	}
	svc.baseURL = server.URL

	ctx := context.Background()

	t.Run("Search", func(t *testing.T) {
		t.Parallel()
		res, err := svc.SearchMessages(ctx, "query", 5)
		if err != nil {
			t.Fatalf("Search failed: %v", err)
		}
		if len(res) != 1 || res[0].ID != "msg123" {
			t.Errorf("Unexpected search results: %+v", res)
		}
	})

	t.Run("Get", func(t *testing.T) {
		t.Parallel()
		msg, err := svc.GetMessage(ctx, "msg123")
		if err != nil {
			t.Fatalf("GetMessage failed: %v", err)
		}
		if msg.Snippet != "Hello world snippet" {
			t.Errorf("Unexpected snippet: %s", msg.Snippet)
		}
		if msg.GetHeader("Subject") != "Test Subject" {
			t.Errorf("Unexpected subject: %s", msg.GetHeader("Subject"))
		}
		if msg.ExtractBody() != "Full body text" {
			t.Errorf("Unexpected body: %s", msg.ExtractBody())
		}
	})
}

func TestExtractBodyFromParts(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name     string
		payload  *Payload
		wantBody string
	}{
		{
			name: "SimpleBody",
			payload: &Payload{
				Body: &Body{
					Data: base64.URLEncoding.EncodeToString([]byte("Simple body")),
				},
			},
			wantBody: "Simple body",
		},
		{
			name: "MultipartAlternativePreferText",
			payload: &Payload{
				Parts: []Part{
					{
						MimeType: "text/plain",
						Body:     &Body{Data: base64.URLEncoding.EncodeToString([]byte("Plain text"))},
					},
					{
						MimeType: "text/html",
						Body:     &Body{Data: base64.URLEncoding.EncodeToString([]byte("<p>HTML text</p>"))},
					},
				},
			},
			wantBody: "Plain text",
		},
		{
			name: "NestedMultipart",
			payload: &Payload{
				Parts: []Part{
					{
						MimeType: "multipart/alternative",
						Parts: []Part{
							{
								MimeType: "text/plain",
								Body:     &Body{Data: base64.URLEncoding.EncodeToString([]byte("Nested plain text"))},
							},
						},
					},
				},
			},
			wantBody: "Nested plain text",
		},
		{
			name: "MixedWithAttachments",
			payload: &Payload{
				Parts: []Part{
					{
						MimeType: "multipart/alternative",
						Parts: []Part{
							{
								MimeType: "text/plain",
								Body:     &Body{Data: base64.URLEncoding.EncodeToString([]byte("Mixed body text"))},
							},
						},
					},
					{
						MimeType: "application/pdf",
						Filename: "test.pdf",
						Body:     &Body{Data: "SOMEBASE64DATA"},
					},
				},
			},
			wantBody: "Mixed body text",
		},
		{
			name: "NoBodyData",
			payload: &Payload{
				Body: &Body{Data: ""},
			},
			wantBody: "",
		},
	}

	for _, tt := range tests {
		tt := tt
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			msg := &Message{Payload: tt.payload}
			got := msg.ExtractBody()
			if !strings.Contains(got, tt.wantBody) {
				t.Errorf("ExtractBody() = %q, want it to contain %q", got, tt.wantBody)
			}
		})
	}
}
