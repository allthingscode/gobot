package main

import (
    "testing"
    "time"
)

func TestEscapeMarkdownV2Chars(t *testing.T) {
    cases := []struct {
        name, in, want string
    }{
        {"plain text unchanged", "hello world", "hello world"},
        {"dot", "v1.0", `v1\.0`},
        {"dash", "foo-bar", `foo\-bar`},
        {"exclamation", "done!", `done\!`},
        {"parens", "(beta)", `\(beta\)`},
        {"underscore", "_name_", `\_name\_`},
        {"asterisk", "*bold*", `\*bold\*`},
        {"backslash escaped first", `a\b`, `a\\b`},
        {"common sentence", "Done. It works!", `Done\. It works\!`},
        {"version", "gobot v1.2.3", `gobot v1\.2\.3`},
    }
    for _, tc := range cases {
        t.Run(tc.name, func(t *testing.T) {
            if got := escapeMarkdownV2Chars(tc.in); got != tc.want {
                t.Errorf("escapeMarkdownV2Chars(%q)\n  got  %q\n  want %q", tc.in, got, tc.want)
            }
        })
    }
}

func TestConvertToMarkdownV2(t *testing.T) {
    cases := []struct {
        name, in, want string
    }{
        {
            "plain text special chars escaped",
            "gobot v1.2 (beta)!",
            `gobot v1\.2 \(beta\)\!`,
        },
        {
            "no special chars pass through",
            "hello world",
            "hello world",
        },
        {
            "code block content not escaped",
            "Example:\n```\nfoo(1.0)\n```\ndone.",
            "Example:\n```\nfoo(1.0)\n```\ndone\\.",
        },
        {
            "inline code content not escaped",
            "Call fmt.Println() like: `fmt.Println(x)` today.",
            "Call fmt\\.Println\\(\\) like: `fmt.Println(x)` today\\.",
        },
        {
            "multiple code spans",
            "Use `a.b` and `c.d` here.",
            "Use `a.b` and `c.d` here\\.",
        },
        {
            "empty string",
            "",
            "",
        },
    }
    for _, tc := range cases {
        t.Run(tc.name, func(t *testing.T) {
            if got := convertToMarkdownV2(tc.in); got != tc.want {
                t.Errorf("convertToMarkdownV2(%q)\n  got  %q\n  want %q", tc.in, got, tc.want)
            }
        })
    }
}

func TestIsDuplicate(t *testing.T) {
    api := &tgAPI{}

    // First call: not a duplicate.
    if api.isDuplicate(1) {
        t.Error("first call should not be a duplicate")
    }

    // Second call with same ID: duplicate.
    if !api.isDuplicate(1) {
        t.Error("second call with same ID should be a duplicate")
    }

    // Different ID: not a duplicate.
    if api.isDuplicate(2) {
        t.Error("different ID should not be a duplicate")
    }

    // Expired entry: should not be a duplicate.
    api.seenMsgs.Store(int64(99), time.Now().Add(-dedupTTL-time.Second))
    if api.isDuplicate(99) {
        t.Error("expired entry should not be treated as duplicate")
    }
}
