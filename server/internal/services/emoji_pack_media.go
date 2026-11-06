package services

import (
	"bytes"
	"context"
	"image"
	"image/color"
	"image/color/palette"
	"image/draw"
	"image/gif"
	"image/png"
	"io"
	"os"
	"path/filepath"

	"gorm.io/gorm"
	"shenliyuan/internal/models"
)

// GIF 的局部增量帧先合成为完整画布，再缩放；逐张缩放局部帧会丢失偏移与处置语义。
func normalizeEmojiPackGIF(src []byte) (NormalizedEmoji, error) {
	decoded, err := gif.DecodeAll(bytes.NewReader(src))
	if err != nil || len(decoded.Image) == 0 {
		return NormalizedEmoji{}, ErrEmojiPackInvalid
	}
	canvas := image.NewRGBA(image.Rect(0, 0, decoded.Config.Width, decoded.Config.Height))
	colors := append(color.Palette{color.Transparent}, palette.Plan9[:255]...)
	output := &gif.GIF{Delay: append([]int(nil), decoded.Delay...), LoopCount: decoded.LoopCount}
	for index, frame := range decoded.Image {
		disposal := byte(gif.DisposalNone)
		if index < len(decoded.Disposal) {
			disposal = decoded.Disposal[index]
		}
		var previous *image.RGBA
		if disposal == gif.DisposalPrevious {
			previous = image.NewRGBA(canvas.Bounds())
			copy(previous.Pix, canvas.Pix)
		}
		draw.Draw(canvas, frame.Bounds(), frame, frame.Bounds().Min, draw.Over)
		resized, width, height := resizeToMax(canvas, EmojiMaxDimension)
		paletted := image.NewPaletted(image.Rect(0, 0, width, height), colors)
		draw.FloydSteinberg.Draw(paletted, paletted.Bounds(), resized, image.Point{})
		output.Image = append(output.Image, paletted)
		output.Disposal = append(output.Disposal, gif.DisposalBackground)
		if disposal == gif.DisposalBackground {
			draw.Draw(canvas, frame.Bounds(), image.Transparent, image.Point{}, draw.Src)
		}
		if previous != nil {
			canvas = previous
		}
	}
	var encoded bytes.Buffer
	if err := gif.EncodeAll(&encoded, output); err != nil {
		return NormalizedEmoji{}, err
	}
	if int64(encoded.Len()) > EmojiMaxCompressedBytes {
		return NormalizedEmoji{}, ErrEmojiFileTooLarge
	}
	thumb, err := encodeThumbnail(output.Image[0], EmojiThumbDimension)
	if err != nil {
		return NormalizedEmoji{}, err
	}
	return NormalizedEmoji{Bytes: encoded.Bytes(), MimeType: "image/gif", Width: output.Image[0].Bounds().Dx(), Height: output.Image[0].Bounds().Dy(), IsAnimated: len(output.Image) > 1, Thumbnail: thumb}, nil
}

// 派生图不进入既有 Manifest，避免改变旧客户端的规范化 Hash。
func emojiPackPreview(src []byte, size int) ([]byte, error) {
	decoded, _, err := image.Decode(bytes.NewReader(src))
	if err != nil {
		return nil, err
	}
	resized, _, _ := resizeToMax(decoded, size)
	var output bytes.Buffer
	err = png.Encode(&output, resized)
	return output.Bytes(), err
}

func (s *EmojiPackService) OpenPreview(ctx context.Context, pack models.CommunityEmojiPack, assetID, variant string) ([]byte, error) {
	size, fileName := 256, assetID+".thumb"
	if variant == "cover" || variant == "icon" {
		assetID = pack.CoverAssetID
		if variant == "icon" && pack.IconAssetID != "" {
			assetID = pack.IconAssetID
		}
		if assetID == "" {
			assetID = "image-1"
		}
		size, fileName = 320, "cover.png"
		if variant == "icon" {
			size, fileName = 96, "icon.png"
		}
	} else if variant != "thumbnail" {
		return nil, gorm.ErrRecordNotFound
	}
	// 先以关系表验证资源身份，不能把请求路径直接交给文件系统。
	file, _, err := s.OpenAsset(ctx, pack.ID, assetID)
	if err != nil {
		return nil, err
	}
	defer file.Close()
	if pack.MediaVersion > 0 {
		data, err := os.ReadFile(filepath.Join(s.root, pack.ID, fileName))
		if err == nil {
			return data, nil
		}
		if !os.IsNotExist(err) {
			return nil, err
		}
	}
	// 历史包无派生图时按已授权的规范化资源生成，不批量改写旧包。
	src, err := io.ReadAll(io.LimitReader(file, EmojiMaxCompressedBytes+1))
	if err != nil || int64(len(src)) > EmojiMaxCompressedBytes {
		return nil, ErrEmojiPackInvalid
	}
	return emojiPackPreview(src, size)
}
