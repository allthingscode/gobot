package logattr

import "log/slog"

// SessionKey returns a slog.Attr for the canonical "session_key" field.
func SessionKey(v string) slog.Attr {
	return slog.String("session_key", v)
}

// UserID returns a slog.Attr for the canonical "user_id" field.
func UserID(v string) slog.Attr {
	return slog.String("user_id", v)
}

// ToolName returns a slog.Attr for the canonical "tool" field.
func ToolName(v string) slog.Attr {
	return slog.String("tool", v)
}

// Model returns a slog.Attr for the canonical "model" field.
func Model(v string) slog.Attr {
	return slog.String("model", v)
}

// Provider returns a slog.Attr for the canonical "provider" field.
func Provider(v string) slog.Attr {
	return slog.String("provider", v)
}

// Attempt returns a slog.Attr for the canonical "attempt" field.
func Attempt(v int) slog.Attr {
	return slog.Int("attempt", v)
}

// Err returns a slog.Attr for the canonical "err" field.
func Err(err error) slog.Attr {
	return slog.Any("err", err)
}
