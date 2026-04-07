package telegram

import (
	"fmt"
	"os"
	"path/filepath"
	"reflect"
	"testing"
)

func TestGetMediaPath(t *testing.T) {
	home, _ := os.UserHomeDir()
	defaultWorkspace := filepath.Join(home, ".nanobot", "workspace")

	tests := []struct {
		name          string
		baseWorkspace string
		originalPath  string
		want          string
	}{
		{
			name:          "empty originalPath",
			baseWorkspace: "/tmp/ws",
			originalPath:  "",
			want:          "",
		},
		{
			name:          "path without .nanobot/media",
			baseWorkspace: "/tmp/ws",
			originalPath:  "/some/other/path/image.png",
			want:          "/some/other/path/image.png",
		},
		{
			name:          "path with .nanobot/media (forward slash)",
			baseWorkspace: "/tmp/ws",
			originalPath:  "/home/user/.nanobot/media/photo.jpg",
			want:          filepath.Join(string(os.PathSeparator), "tmp", "ws", "media", "photo.jpg"),
		},
		{
			name:          "path with .nanobot\\media (backslash)",
			baseWorkspace: filepath.Join("ws_root", "ws"),
			originalPath:  filepath.Join("some", "path", ".nanobot", "media", "document.pdf"),
			want:          filepath.Join("ws_root", "ws", "media", "document.pdf"),
		},
		{
			name:          "path with mixed case (.NANOBOT/Media)",
			baseWorkspace: "/tmp/ws",
			originalPath:  "/path/to/.NANOBOT/Media/video.mp4",
			want:          filepath.Join(string(os.PathSeparator), "tmp", "ws", "media", "video.mp4"),
		},
		{
			name:          "empty baseWorkspace uses default",
			baseWorkspace: "",
			originalPath:  "/path/to/.nanobot/media/audio.mp3",
			want:          filepath.Join(defaultWorkspace, "media", "audio.mp3"),
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := GetMediaPath(tt.baseWorkspace, tt.originalPath)
			if got != tt.want {
				t.Errorf("GetMediaPath() = %v, want %v", got, tt.want)
			}
		})
	}
}

func TestDetectThreadMetadata(t *testing.T) {
	tests := []struct {
		name            string
		messageThreadID int64
		chatID          int64
		want            map[string]any
	}{
		{
			name:            "zero messageThreadID",
			messageThreadID: 0,
			chatID:          12345,
			want:            nil,
		},
		{
			name:            "non-zero messageThreadID",
			messageThreadID: 99,
			chatID:          55555,
			want: map[string]any{
				"message_thread_id":    int64(99),
				"session_key_override": "telegram:55555:99",
			},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := DetectThreadMetadata(tt.messageThreadID, tt.chatID)
			if !reflect.DeepEqual(got, tt.want) {
				t.Errorf("DetectThreadMetadata() = %v, want %v", got, tt.want)
			}

			if tt.want != nil {
				// Verify session_key_override format exactly
				wantSessionKey := fmt.Sprintf("telegram:%d:%d", tt.chatID, tt.messageThreadID)
				if got["session_key_override"] != wantSessionKey {
					t.Errorf("session_key_override = %v, want %v", got["session_key_override"], wantSessionKey)
				}
			}
		})
	}
}
