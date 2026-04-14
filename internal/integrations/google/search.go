package google

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"
	"time"
)

//nolint:gochecknoglobals // Defaults for search service; intentional package-level singletons
var DefaultBaseURL = "https://www.googleapis.com/customsearch/v1"

// DefaultSearchClient is the default HTTP client used for Google searches.
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
		return nil, fmt.Errorf("create search request: %w", err)
	}

	resp, err := s.HTTPClient.Do(req)
	if err != nil {
		return nil, fmt.Errorf("search request: %w", err)
	}
	defer func() { _ = resp.Body.Close() }()

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, fmt.Errorf("read response: %w", err)
	}

	if resp.StatusCode != http.StatusOK {
		var errResp SearchResponse
		if err := json.Unmarshal(body, &errResp); err == nil && errResp.Error != nil {
			return nil, fmt.Errorf("google API %d: %s", resp.StatusCode, errResp.Error.Message)
		}
		return nil, fmt.Errorf("google API %d: %s", resp.StatusCode, string(body))
	}

	var searchResp SearchResponse
	if err := json.Unmarshal(body, &searchResp); err != nil {
		return nil, fmt.Errorf("parse response: %w", err)
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
