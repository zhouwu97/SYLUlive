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

func TestPrivateMessagePreviewUsesTextForMixedStickerMessage(t *testing.T) {
	stickerID := "0cc4a3688e7b222b977fef3a078619b6"
	mixed := models.Message{Content: "晚安", StickerID: &stickerID}
	if got, want := privateMessagePreview(mixed), "晚安"; got != want {
		t.Fatalf("mixed sticker preview = %q, want %q", got, want)
	}

	pure := models.Message{Content: stickerFallbackText, StickerID: &stickerID}
	if got, want := privateMessagePreview(pure), "发来一个表情"; got != want {
		t.Fatalf("pure sticker preview = %q, want %q", got, want)
	}

	fileID := uint(123)
	img := models.Message{FileID: &fileID}
	if got, want := privateMessagePreview(img), "发来一张图片"; got != want {
		t.Fatalf("image preview = %q, want %q", got, want)
	}
}
