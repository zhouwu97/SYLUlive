package handlers

import (
	"strings"
	"testing"

	"shenliyuan/internal/models"
)

func TestPrivateMessagePreviewPreservesGraphemeClusters(t *testing.T) {
	message := models.Message{Content: strings.Repeat("a", 49) + "👨‍👩‍👧‍👦B"}
	want := strings.Repeat("a", 49) + "👨‍👩‍👧‍👦..."
	if got := privateMessagePreview(message); got != want {
		t.Fatalf("family preview = %q, want %q", got, want)
	}

	message.Content = "😀😀😀"
	if got, want := privateMessagePreview(message), "😀😀😀"; got != want {
		t.Fatalf("short emoji preview = %q, want %q", got, want)
	}
}
