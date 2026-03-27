# Go CLI (Cobra) Best Practices

## 1. Separate CLI Logic from Business Logic
Your `cmd/` packages should *only* handle parsing flags, reading arguments, and wiring up dependencies. All actual business logic must live in `internal/` or `pkg/`.
*   **Do:** Read `os.Args` in `cmd`, then pass a clean struct to an `internal` function.
*   **Don't:** Call databases, APIs, or perform complex data manipulation inside a Cobra `Run` function.

## 2. Prefer `RunE` over `Run`
Always use `RunE` in your `cobra.Command` definitions. This allows you to return a standard Go `error` up the chain instead of calling `log.Fatal()` or `os.Exit(1)` deep inside your command logic.
*   **Why:** Returning an error lets Cobra handle the error formatting consistently, and more importantly, makes your CLI code testable. A deep `os.Exit(1)` will crash the test runner.

```go
// Good
func cmdRun() *cobra.Command {
	return &cobra.Command{
		Use:   "run",
		Short: "Run the agent",
		RunE: func(cmd *cobra.Command, args []string) error {
            cfg, err := loadConfig()
            if err != nil {
                return fmt.Errorf("failed to load config: %w", err)
            }
			return agent.Run(cfg)
		},
	}
}
```

## 3. Avoid Global State and `init()` for Flags
While standard Cobra tutorials often use `init()` and global variables for flags, this pattern makes unit testing commands extremely difficult due to shared state between tests.
*   **Better:** Define flags locally within the function that creates the command, or bind them to a struct passed into the command builder.

```go
func cmdServe() *cobra.Command {
    var port int
    cmd := &cobra.Command{
        Use: "serve",
        RunE: func(cmd *cobra.Command, args []string) error {
            return server.Start(port)
        },
    }
    cmd.Flags().IntVarP(&port, "port", "p", 8080, "Port to listen on")
    return cmd
}
```

## 4. Silence Errors and Usage on Execution Failures
By default, if `RunE` returns an error, Cobra will print the error *and* the help/usage text. This is annoying if the command failed due to a runtime error (e.g., database timeout) rather than a syntax error.
*   **Fix:** Set `SilenceUsage: true` and `SilenceErrors: true` on your root command, and handle the final error printing yourself in `main()`.

```go
func main() {
    root := &cobra.Command{
        SilenceUsage:  true,
        SilenceErrors: true,
        // ...
    }
    if err := root.Execute(); err != nil {
        fmt.Fprintln(os.Stderr, "Error:", err)
        os.Exit(1)
    }
}
```
