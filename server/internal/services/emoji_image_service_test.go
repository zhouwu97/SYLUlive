package services

import (
	"bytes"
	"image"
	"image/color"
	"image/gif"
	"image/jpeg"
	"image/png"
	"testing"
)

func TestNormalizeEmojiKeepsTransparentPngAndBoundsStaticImage(t *testing.T) {
	source := image.NewNRGBA(image.Rect(0, 0, 1600, 800))
	source.SetNRGBA(0, 0, color.NRGBA{R: 10, G: 20, B: 30, A: 80})
	var input bytes.Buffer
	if err := png.Encode(&input, source); err != nil {
		t.Fatal(err)
	}

	result, err := NormalizeEmoji(input.Bytes(), "image/png")
	if err != nil {
		t.Fatal(err)
	}
	if result.MimeType != "image/png" || result.IsAnimated {
		t.Fatalf("result=%+v", result)
	}
	if result.Width != 512 || result.Height != 256 {
		t.Fatalf("尺寸=%dx%d, want 512x256", result.Width, result.Height)
	}
	decoded, err := png.Decode(bytes.NewReader(result.Bytes))
	if err != nil {
		t.Fatal(err)
	}
	_, _, _, alpha := decoded.At(0, 0).RGBA()
	if alpha == 0xffff {
		t.Fatal("透明 PNG 的 alpha 通道丢失")
	}
}

func TestNormalizeEmojiConvertsOpaquePngToJpeg(t *testing.T) {
	source := image.NewRGBA(image.Rect(0, 0, 800, 400))
	for y := 0; y < 400; y++ {
		for x := 0; x < 800; x++ {
			source.SetRGBA(x, y, color.RGBA{R: 30, G: 80, B: 120, A: 255})
		}
	}
	var input bytes.Buffer
	if err := png.Encode(&input, source); err != nil {
		t.Fatal(err)
	}

	result, err := NormalizeEmoji(input.Bytes(), "image/png")
	if err != nil {
		t.Fatal(err)
	}
	if result.MimeType != "image/jpeg" || result.Width != 512 || result.Height != 256 {
		t.Fatalf("result=%+v", result)
	}
	if _, err := jpeg.Decode(bytes.NewReader(result.Bytes)); err != nil {
		t.Fatalf("输出不是 JPEG: %v", err)
	}
}

func TestNormalizeEmojiReencodesGifWithFramesAndDelays(t *testing.T) {
	first := image.NewPaletted(image.Rect(0, 0, 800, 400), []color.Color{color.RGBA{R: 255, A: 255}})
	second := image.NewPaletted(image.Rect(0, 0, 800, 400), []color.Color{color.RGBA{B: 255, A: 255}})
	var input bytes.Buffer
	if err := gif.EncodeAll(&input, &gif.GIF{
		Image: []*image.Paletted{first, second},
		Delay: []int{5, 12},
	}); err != nil {
		t.Fatal(err)
	}

	result, err := NormalizeEmoji(input.Bytes(), "image/gif")
	if err != nil {
		t.Fatal(err)
	}
	if result.MimeType != "image/gif" || !result.IsAnimated {
		t.Fatalf("result=%+v", result)
	}
	decoded, err := gif.DecodeAll(bytes.NewReader(result.Bytes))
	if err != nil {
		t.Fatal(err)
	}
	if len(decoded.Image) != 2 || decoded.Delay[0] != 5 || decoded.Delay[1] != 12 {
		t.Fatalf("frames=%d delays=%v", len(decoded.Image), decoded.Delay)
	}
	if decoded.Image[0].Bounds().Dx() != 512 || decoded.Image[0].Bounds().Dy() != 256 {
		t.Fatalf("GIF 尺寸=%v", decoded.Image[0].Bounds())
	}
}

func TestBuildEmojiThumbnailUsesFirstGifFrame(t *testing.T) {
	first := image.NewPaletted(image.Rect(0, 0, 800, 400), []color.Color{color.RGBA{R: 255, A: 255}})
	second := image.NewPaletted(image.Rect(0, 0, 800, 400), []color.Color{color.RGBA{B: 255, A: 255}})
	var input bytes.Buffer
	if err := gif.EncodeAll(&input, &gif.GIF{Image: []*image.Paletted{first, second}, Delay: []int{1, 1}}); err != nil {
		t.Fatal(err)
	}
	result, err := NormalizeEmoji(input.Bytes(), "image/gif")
	if err != nil {
		t.Fatal(err)
	}
	thumb, err := png.Decode(bytes.NewReader(result.Thumbnail))
	if err != nil {
		t.Fatal(err)
	}
	if thumb.Bounds().Dx() != 480 || thumb.Bounds().Dy() != 240 {
		t.Fatalf("缩略图尺寸=%v", thumb.Bounds())
	}
	r, g, b, _ := thumb.At(0, 0).RGBA()
	if r <= b || g != 0 {
		t.Fatalf("缩略图没有使用 GIF 首帧: rgba=%d,%d,%d", r, g, b)
	}
}
