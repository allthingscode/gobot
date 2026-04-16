package main

import (
	"bytes"
	"testing"
)

func TestStripBOM(t *testing.T) {
	t.Parallel()
	
	// Case 1: No BOM
	data := []byte("hello")
	if got := stripBOM(data); !bytes.Equal(got, data) {
		t.Errorf("got %q, want %q", got, data)
	}

	// Case 2: BOM present
	dataWithBOM := append([]byte{0xef, 0xbb, 0xbf}, []byte("world")...)
	if got := stripBOM(dataWithBOM); !bytes.Equal(got, []byte("world")) {
		t.Errorf("got %q, want 'world'", got)
	}
}
