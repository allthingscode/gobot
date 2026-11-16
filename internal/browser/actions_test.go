//nolint:testpackage // exercises the typed adapter without a browser
package browser

import (
	"context"
	"errors"
	"reflect"
	"strings"
	"testing"
	"time"

	"github.com/chromedp/chromedp"
)

func offlineDo(ctx context.Context, actions ...chromedp.Action[chromedp.Void]) error {
	_, err := chromedp.Steps(actions...)(ctx, nil)
	return err
}

func TestResultActionValues(t *testing.T) {
	t.Parallel()
	t.Run("title", func(t *testing.T) { t.Parallel(); checkResultAction(t, "Page title") })
	t.Run("text list", func(t *testing.T) { t.Parallel(); checkResultAction(t, []string{"first", "second"}) })
	t.Run("screenshot", func(t *testing.T) { t.Parallel(); checkResultAction(t, []byte{0xff, 0xd8, 1}) })
	t.Run("nil list", func(t *testing.T) { t.Parallel(); checkResultAction[[]string](t, nil) })
}

func checkResultAction[T any](t *testing.T, want T) {
	t.Helper()
	for _, fail := range []bool{false, true} {
		ctx, cancel := context.WithTimeout(context.Background(), time.Second)
		target := &chromedp.Target{}
		var got T
		sentinel := errors.New("action failed")
		action := ResultAction[T]{Result: &got, Task: func(actual context.Context, actualTarget *chromedp.Target) (T, error) {
			if actual != ctx || actualTarget != target {
				t.Fatal("adapter replaced context or target")
			}
			if fail {
				return want, sentinel
			}
			return want, nil
		}}
		_, err := action.action()(ctx, target)
		cancel()
		wantErr := error(nil)
		expected := want
		if fail {
			wantErr = sentinel
			var zero T
			expected = zero
		}
		if !errors.Is(err, wantErr) || !reflect.DeepEqual(got, expected) {
			t.Fatalf("result = %v, %v; want %v, %v", got, err, expected, wantErr)
		}
	}
}

func TestExecutorSequence(t *testing.T) {
	t.Parallel()
	for _, tt := range []struct {
		failAt    string
		wantCalls []string
		wantTitle string
	}{
		{"", []string{"navigate", "title", "wait"}, "title value"},
		{"navigate", []string{"navigate"}, ""},
		{"title", []string{"navigate", "title"}, ""},
		{"wait", []string{"navigate", "title", "wait"}, "title value"},
	} {
		t.Run("fail at "+tt.failAt, func(t *testing.T) {
			t.Parallel()
			var calls []string
			var title string
			sentinel := errors.New("step failed")
			step := func(name string) chromedp.Action[chromedp.Void] {
				return recordedStep(&calls, name, tt.failAt, sentinel)
			}
			titleAction := ResultAction[string]{Result: &title, Task: func(context.Context, *chromedp.Target) (string, error) {
				_, err := step("title")(context.Background(), nil)
				return "title value", err
			}}
			err := runActions(context.Background(), offlineDo, VoidAction(step("navigate")), titleAction, VoidAction(step("wait")))
			var wantErr error
			if tt.failAt != "" {
				wantErr = sentinel
			}
			if !reflect.DeepEqual(calls, tt.wantCalls) || !errors.Is(err, wantErr) {
				t.Fatalf("calls=%v err=%v; want %v, %v", calls, err, tt.wantCalls, wantErr)
			}
			if title != tt.wantTitle {
				t.Fatalf("unexpected title %q after %q failure", title, tt.failAt)
			}
		})
	}
}

func recordedStep(calls *[]string, name, failAt string, failure error) chromedp.Action[chromedp.Void] {
	return chromedp.Func(func(context.Context, *chromedp.Target) error {
		*calls = append(*calls, name)
		if name == failAt {
			return failure
		}
		return nil
	})
}

func TestExecutorContextErrors(t *testing.T) {
	t.Parallel()
	for _, name := range []string{"canceled", "deadline"} {
		t.Run(name, func(t *testing.T) {
			t.Parallel()
			ctx, cancel := context.WithCancel(context.Background())
			want := context.Canceled
			if name == "deadline" {
				cancel()
				ctx, cancel = context.WithDeadline(context.Background(), time.Now().Add(-time.Second))
				want = context.DeadlineExceeded
			} else {
				cancel()
			}
			defer cancel()
			err := runActions(ctx, offlineDo, VoidAction(chromedp.Func(func(actual context.Context, _ *chromedp.Target) error {
				if actual != ctx {
					t.Fatal("context changed")
				}
				return actual.Err()
			})))
			if !errors.Is(err, want) || !strings.Contains(err.Error(), "chromedp run failed") {
				t.Fatalf("error = %v; want wrapped %v", err, want)
			}
		})
	}
}

func TestDefaultExecutorInvalidContext(t *testing.T) {
	t.Parallel()
	if err := (DefaultExecutor{}).Run(context.Background()); !errors.Is(err, chromedp.ErrInvalidContext) {
		t.Fatalf("error = %v; want invalid context", err)
	}
}
