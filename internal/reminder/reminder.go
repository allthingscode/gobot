// Package reminder persists and delivers one-shot reminders without an agent or scheduler.
package reminder

import (
	"errors"
	"fmt"
	"regexp"
	"strings"
	"time"
	"unicode/utf8"
)

// State is the durable delivery state.
type State string

// Reminder states. Only pending work may be cancelled or claimed.
const (
	Pending     State = "pending"
	Dispatching State = "dispatching"
	Delivered   State = "delivered"
	Cancelled   State = "cancelled"
	Failed      State = "failed"
)

// ErrNotFound hides both unknown IDs and reminders belonging to other owners.
var ErrNotFound = errors.New("reminder not found for this owner")

// Owner identifies a Telegram sender within a chat, independently of its topic.
type Owner struct {
	ChatID   int64 `json:"chat_id"`
	SenderID int64 `json:"sender_id"`
}

// Validate rejects absent or malformed Telegram identities.
func (o Owner) Validate() error {
	if o.ChatID == 0 || o.SenderID <= 0 {
		return errors.New("reminder: valid chat and positive sender IDs required")
	}
	return nil
}

// Reminder contains the immutable destination and persisted delivery progress.
type Reminder struct {
	ID          string    `json:"id"`
	Owner       Owner     `json:"-"`
	TopicID     int64     `json:"topic_id"`
	Text        string    `json:"text"`
	Due         time.Time `json:"due"`
	State       State     `json:"state"`
	Attempts    int       `json:"attempts"`
	NextAttempt time.Time `json:"next_attempt"`
	Failure     string    `json:"failure,omitempty"`
}

// ParseTime accepts only a resolved RFC3339 instant; local times need clarification.
func ParseTime(value string, now time.Time) (time.Time, error) {
	// Compile locally to keep validation immutable without package-level state.
	pattern := `^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{1,9})?(Z|[+-](0\d|1\d|2[0-3]):[0-5]\d)$`
	if !regexp.MustCompile(pattern).MatchString(value) || strings.HasSuffix(value, "-00:00") {
		return time.Time{}, errors.New("reminder: clarify the time with a resolved RFC3339 instant and explicit offset, for example 2027-01-02T09:00:00-06:00")
	}
	due, err := time.Parse(time.RFC3339Nano, value)
	if err != nil {
		return time.Time{}, fmt.Errorf("reminder: clarify invalid time: %w", err)
	}
	if due.Year() < 1 || !due.After(now) {
		return time.Time{}, errors.New("reminder: clarify a time in the future")
	}
	return due, nil
}

func validateCreate(owner Owner, topicID int64, text string, due, now time.Time) error {
	if err := owner.Validate(); err != nil {
		return err
	}
	if topicID < 0 {
		return errors.New("reminder: topic ID must not be negative")
	}
	if strings.TrimSpace(text) == "" || !utf8.ValidString(text) || len(text) > 4096 {
		return errors.New("reminder: text must be nonempty valid UTF-8 and at most 4096 bytes")
	}
	_, err := ParseTime(due.Format(time.RFC3339Nano), now)
	return err
}

func retryDelay(attempts int) time.Duration {
	if attempts == 1 {
		return time.Minute
	}
	return 5 * time.Minute
}
