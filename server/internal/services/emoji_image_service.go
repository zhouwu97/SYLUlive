package services

import (
	"bytes"
	"errors"
	"fmt"
	"image"
	"image/color/palette"
	"image/gif"
	"image/jpeg"
	"image/png"

	xdraw "golang.org/x/image/draw"
	stdDraw "image/draw"
)

const (
	EmojiMaxDimension             = 512
	EmojiThumbDimension           = 480
	EmojiMaxCompressedBytes int64 = 10 * 1024 * 1024
)

var ErrEmojiFileTooLarge = errors.New("compressed emoji file exceeds 10MB")

// NormalizedEmoji 是服务端最终保存的表情资源，不包含原始上传文件。
type NormalizedEmoji struct {
	Bytes      []byte
	MimeType   string
	Width      int
	Height     int
	IsAnimated bool
	Thumbnail  []byte
}

// NormalizeEmoji 将允许的图片格式统一缩放和编码，并同时生成网格首帧缩略图。
func NormalizeEmoji(src []byte, mimeType string) (NormalizedEmoji, error) {
	if int64(len(src)) > EmojiMaxCompressedBytes {
		return NormalizedEmoji{}, ErrEmojiFileTooLarge
	}
	if len(src) == 0 {
		return NormalizedEmoji{}, errors.New("emoji file is empty")
	}

	var result NormalizedEmoji
	switch mimeType {
	case "image/gif":
		decoded, err := gif.DecodeAll(bytes.NewReader(src))
		if err != nil || len(decoded.Image) == 0 {
			if err == nil {
				err = errors.New("GIF contains no frames")
			}
			return NormalizedEmoji{}, fmt.Errorf("decode gif: %w", err)
		}
		frames := make([]*image.Paletted, len(decoded.Image))
		for index, frame := range decoded.Image {
			resized, width, height := resizeToMax(frame, EmojiMaxDimension)
			paletteImage := image.NewPaletted(image.Rect(0, 0, width, height), palette.Plan9)
			stdDraw.FloydSteinberg.Draw(paletteImage, paletteImage.Bounds(), resized, image.Point{})
			frames[index] = paletteImage
		}
		var encoded bytes.Buffer
		gifData := &gif.GIF{
			Image:     frames,
			Delay:     append([]int(nil), decoded.Delay...),
			Disposal:  append([]byte(nil), decoded.Disposal...),
			LoopCount: decoded.LoopCount,
		}
		if err := gif.EncodeAll(&encoded, gifData); err != nil {
			return NormalizedEmoji{}, fmt.Errorf("encode gif: %w", err)
		}
		result.Bytes = encoded.Bytes()
		result.MimeType = mimeType
		result.Width = frames[0].Bounds().Dx()
		result.Height = frames[0].Bounds().Dy()
		result.IsAnimated = len(frames) > 1
		result.Thumbnail, err = encodeThumbnail(frames[0], EmojiThumbDimension)
		if err != nil {
			return NormalizedEmoji{}, err
		}
	default:
		decoded, format, err := image.Decode(bytes.NewReader(src))
		if err != nil {
			return NormalizedEmoji{}, fmt.Errorf("decode static image: %w", err)
		}
		if format != "jpeg" && format != "png" {
			return NormalizedEmoji{}, fmt.Errorf("unsupported image format: %s", format)
		}
		resized, width, height := resizeToMax(decoded, EmojiMaxDimension)
		transparent := hasTransparency(decoded)
		result.MimeType = "image/jpeg"
		if format == "png" && transparent {
			result.MimeType = "image/png"
		}
		var encoded bytes.Buffer
		var encodeErr error
		if result.MimeType == "image/png" {
			encodeErr = png.Encode(&encoded, resized)
		} else {
			encodeErr = jpeg.Encode(&encoded, resized, &jpeg.Options{Quality: 82})
		}
		if encodeErr != nil {
			return NormalizedEmoji{}, encodeErr
		}
		result.Bytes = encoded.Bytes()
		result.Width = width
		result.Height = height
		result.Thumbnail, err = encodeThumbnail(resized, EmojiThumbDimension)
		if err != nil {
			return NormalizedEmoji{}, err
		}
	}
	if int64(len(result.Bytes)) > EmojiMaxCompressedBytes {
		return NormalizedEmoji{}, ErrEmojiFileTooLarge
	}
	return result, nil
}

// BuildEmojiThumbnail 从已规范化资源生成静态 PNG 缩略图。
func BuildEmojiThumbnail(normalized NormalizedEmoji) ([]byte, error) {
	if normalized.IsAnimated || normalized.MimeType == "image/gif" {
		decoded, err := gif.DecodeAll(bytes.NewReader(normalized.Bytes))
		if err != nil || len(decoded.Image) == 0 {
			return nil, fmt.Errorf("decode normalized gif: %w", err)
		}
		return encodeThumbnail(decoded.Image[0], EmojiThumbDimension)
	}
	decoded, _, err := image.Decode(bytes.NewReader(normalized.Bytes))
	if err != nil {
		return nil, fmt.Errorf("decode normalized image: %w", err)
	}
	return encodeThumbnail(decoded, EmojiThumbDimension)
}

func resizeToMax(src image.Image, maxDimension int) (image.Image, int, int) {
	bounds := src.Bounds()
	width, height := bounds.Dx(), bounds.Dy()
	if width <= 0 || height <= 0 {
		return image.NewRGBA(image.Rect(0, 0, 1, 1)), 1, 1
	}
	targetWidth, targetHeight := width, height
	if width > maxDimension || height > maxDimension {
		scale := float64(maxDimension) / float64(max(width, height))
		targetWidth = max(1, int(float64(width)*scale))
		targetHeight = max(1, int(float64(height)*scale))
	}
	resized := image.NewRGBA(image.Rect(0, 0, targetWidth, targetHeight))
	xdraw.CatmullRom.Scale(resized, resized.Bounds(), src, bounds, xdraw.Over, nil)
	return resized, targetWidth, targetHeight
}

func encodeThumbnail(src image.Image, maxDimension int) ([]byte, error) {
	resized, _, _ := resizeToMax(src, maxDimension)
	var output bytes.Buffer
	if err := png.Encode(&output, resized); err != nil {
		return nil, fmt.Errorf("encode emoji thumbnail: %w", err)
	}
	return output.Bytes(), nil
}

func hasTransparency(src image.Image) bool {
	bounds := src.Bounds()
	for y := bounds.Min.Y; y < bounds.Max.Y; y++ {
		for x := bounds.Min.X; x < bounds.Max.X; x++ {
			_, _, _, alpha := src.At(x, y).RGBA()
			if alpha != 0xffff {
				return true
			}
		}
	}
	return false
}
