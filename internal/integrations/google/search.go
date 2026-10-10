package google

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"strings"
	"time"
)

//nolint:gochecknoglobals // Defaults for search service; intentional package-level singletons
var DefaultBaseURL = "https://www.googleapis.com/customsearch/v1"

// DefaultSearchClient is the default HTTP client used for Google searches.
//
//nolint:gochecknoglobals // Shared HTTP client for search service
var DefaultSearchClient = &http.Client{Timeout: 30 * time.Second}

// SearchService handles communication with the Google Custom Search API.
type SearchService struct {
	BaseURL    string
	HTTPClient *http.Client
}

// NewSearchService creates a new SearchService with default settings.
func NewSearchService() *SearchService {
	return &SearchService{
		BaseURL:    DefaultBaseURL,
		HTTPClient: DefaultSearchClient,
	}
}

// SearchResult represents a single item from the Google Custom Search results.
type SearchResult struct {
	Title   string `json:"title"`
	Link    string `json:"link"`
	Snippet string `json:"snippet"`
}

// SearchResponse is the top-level response from the Custom Search API.
type SearchResponse struct {
	Items []SearchResult `json:"items"`
	Error *struct {
		Message string `json:"message"`
	} `json:"error"`
}

// searchError keeps opaque causes available for classification without rendering
// their credential-bearing URLs or arbitrary transport/response text.
type searchError struct {
	message string
	cause   error
}

func (e *searchError) Error() string { return e.message }
func (e *searchError) Unwrap() error { return e.cause }

func (e *searchError) Timeout() bool {
	for cause := e.cause; cause != nil; cause = errors.Unwrap(cause) {
		var timeout net.Error
		if errors.As(cause, &timeout) && timeout.Timeout() {
			return true
		}
	}
	return false
}

// Temporary is retained for the legacy net.Error classification interface.
func (e *searchError) Temporary() bool { return e.Timeout() }

func safeSearchError(message string, cause error) error {
	var original *url.Error
	if errors.As(cause, &original) {
		copyError := *original
		copyError.URL = "[redacted]"
		cause = &copyError
	}
	return &searchError{message: message, cause: cause}
}

func searchAPIDiagnostic(body []byte, apiKey string) string {
	var response SearchResponse
	if json.Unmarshal(body, &response) == nil && response.Error != nil {
		message := response.Error.Message
		if (message == "invalid key or cx" || message == "bad request") && !strings.Contains(message, apiKey) {
			return message
		}
	}
	return "request rejected"
}

// ExecuteSearch performs a web search using the Google Custom Search API with default settings.
func ExecuteSearch(ctx context.Context, apiKey, cx, query string) ([]SearchResult, error) {
	svc := NewSearchService()
	return svc.Execute(ctx, apiKey, cx, query)
}

// Execute performs a web search using the SearchService.
func (s *SearchService) Execute(ctx context.Context, apiKey, cx, query string) ([]SearchResult, error) {
	if apiKey == "" || cx == "" {
		return nil, fmt.Errorf("google search: apiKey and customCx are required")
	}

	params := url.Values{}
	params.Set("key", apiKey)
	params.Set("cx", cx)
	params.Set("q", query)

	fullURL := s.BaseURL + "?" + params.Encode()

	req, err := http.NewRequestWithContext(ctx, http.MethodGet, fullURL, http.NoBody)
	if err != nil {
		return nil, safeSearchError("create search request: invalid request", err)
	}

	resp, err := s.HTTPClient.Do(req)
	if err != nil {
		return nil, safeSearchError("search request: transport or redirect failure", err)
	}
	defer func() { _ = resp.Body.Close() }()

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, safeSearchError("read response: read failure", err)
	}

	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("google API %d: %s", resp.StatusCode, searchAPIDiagnostic(body, apiKey))
	}

	var searchResp SearchResponse
	if err := json.Unmarshal(body, &searchResp); err != nil {
		return nil, safeSearchError("parse response: decode failure", err)
	}

	return searchResp.Items, nil
}

// FormatSearchMarkdown converts search results into a readable Markdown list.
func FormatSearchMarkdown(results []SearchResult) string {
	if len(results) == 0 {
		return "No results found."
	}

	var sb strings.Builder
	sb.WriteString("### Google Search Results\n\n")
	for i, res := range results {
		fmt.Fprintf(&sb, "%d. **[%s](%s)**\n", i+1, res.Title, res.Link)
		fmt.Fprintf(&sb, "   %s\n\n", strings.ReplaceAll(res.Snippet, "\n", " "))
	}
	return sb.String()
}
