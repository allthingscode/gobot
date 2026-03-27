# Go Testing Patterns

## 1. Table-Driven Tests
This is the standard pattern for Go testing. It makes tests easy to read, extend, and debug. Define a slice of anonymous structs, iterate over them, and use `t.Run()`.

```go
func TestFormatStrategicError(t *testing.T) {
	tests := []struct {
		name  string
		input string
		want  string
	}{
		{
			name:  "context overflow",
			input: "Error: too many tokens in prompt",
			want:  "[STRATEGIC] Context Overflow (400): ...",
		},
		{
			name:  "rate limit",
			input: "RateLimitError: 429",
			want:  "[STRATEGIC] Capacity Limit Reached (429): ...",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := FormatStrategicError(tt.input)
			if got != tt.want {
				t.Errorf("FormatStrategicError() = %v, want %v", got, tt.want)
			}
		})
	}
}
```

## 2. Test Parallelization (`t.Parallel()`)
To speed up test execution, mark tests as parallel where safe.
*   **Rule:** Only use `t.Parallel()` if the test does not mutate global state, the filesystem, or a shared database.
*   **Pitfall:** When running parallel subtests in a loop prior to Go 1.22, you must capture the loop variable locally (`tc := tt`), otherwise the parallel tests will all evaluate the last item in the slice. (Go 1.22 fixes this, but it's good practice to be aware of).

```go
for _, tt := range tests {
    tt := tt // Capture range variable (pre-Go 1.22)
    t.Run(tt.name, func(t *testing.T) {
        t.Parallel()
        // ...
    })
}
```

## 3. Using `t.Helper()`
If you extract setup or assertion logic into a helper function, always call `t.Helper()` at the start of that function. This tells the Go test runner to report failures at the line where the helper was *called*, not inside the helper itself, making debugging much easier.

```go
func assertNoError(t *testing.T, err error) {
    t.Helper()
    if err != nil {
        t.Fatalf("unexpected error: %v", err)
    }
}
```

## 4. Testing Pure Logic (No External API Calls)
Our `internal/` mandate strictly prohibits external API calls during unit tests.
*   **Strategy:** Define small, focused interfaces for anything that performs I/O or hits an API. In your tests, provide a mock or stub implementation of that interface.
*   **Filesystem:** Use `os.MkdirTemp` and `t.TempDir()` to generate isolated, temporary directories that automatically clean up after the test finishes.

```go
func TestLoadConfig(t *testing.T) {
    // Generate a temporary file to safely test file I/O
    tmpDir := t.TempDir()
    cfgPath := filepath.Join(tmpDir, "config.json")
    // ... write dummy json ...
    cfg, err := LoadFrom(cfgPath)
    // ...
}
```
