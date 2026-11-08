package services

import (
	"bytes"
	"encoding/binary"
	"image"
	"image/draw"
	"image/gif"
	"io"
	"math"
	"os"
)

// GIF 首帧有时是角落里极小的增量帧。仅在首帧几乎透明且文件规模可控时，
// 按 GIF 的偏移和处置规则合成各帧，选取可见内容最完整的一帧作为静态预览。
// 超出预算或格式异常时回退首帧；原动画始终不变。
func representativeGIFFrame(source *os.File, first image.Image, width, height int) image.Image {
	canvasBounds := image.Rect(0, 0, width, height)
	firstBounds := first.Bounds().Intersect(canvasBounds)
	if coverage(first, firstBounds, canvasBounds) >= 0.01 {
		return first
	}
	if _, err := source.Seek(0, io.SeekStart); err != nil {
		return first
	}
	const maxBytes = 5 * 1024 * 1024
	data, err := io.ReadAll(io.LimitReader(source, maxBytes+1))
	if err != nil || len(data) > maxBytes || !gifSamplingWithinBudget(data, width, height) {
		return first
	}
	animation, err := gif.DecodeAll(bytes.NewReader(data))
	if err != nil || len(animation.Image) < 2 || animation.Config.Width != width || animation.Config.Height != height {
		return first
	}
	canvas := image.NewNRGBA(canvasBounds)
	var best *image.NRGBA
	bestCoverage := coverage(first, firstBounds, canvasBounds)
	initialCoverage := bestCoverage
	for index, frame := range animation.Image {
		disposal := byte(gif.DisposalNone)
		if index < len(animation.Disposal) {
			disposal = animation.Disposal[index]
		}
		var previous []byte
		if disposal == gif.DisposalPrevious {
			previous = append([]byte(nil), canvas.Pix...)
		}
		draw.Draw(canvas, frame.Bounds(), frame, frame.Bounds().Min, draw.Over)
		if visible := coverage(canvas, canvasBounds, canvasBounds); visible > bestCoverage {
			bestCoverage = visible
			if best == nil {
				best = image.NewNRGBA(canvasBounds)
			}
			copy(best.Pix, canvas.Pix)
		}
		if disposal == gif.DisposalBackground {
			draw.Draw(canvas, frame.Bounds(), image.Transparent, image.Point{}, draw.Src)
		} else if previous != nil {
			copy(canvas.Pix, previous)
		}
	}
	if best != nil && bestCoverage >= 0.01 && bestCoverage > initialCoverage*4 {
		return best
	}
	return first
}

func coverage(img image.Image, bounds, canvas image.Rectangle) float64 {
	if bounds.Empty() || canvas.Empty() {
		return 0
	}
	// 采样限制判断成本；以逻辑画布面积归一化局部帧。
	step := max(1, int(math.Sqrt(float64(bounds.Dx()*bounds.Dy())/10000)))
	visible, samples := 0, 0
	for y := bounds.Min.Y; y < bounds.Max.Y; y += step {
		for x := bounds.Min.X; x < bounds.Max.X; x += step {
			_, _, _, a := img.At(x, y).RGBA()
			if a > 0 {
				visible++
			}
			samples++
		}
	}
	return float64(visible) / float64(samples) * float64(bounds.Dx()*bounds.Dy()) / float64(canvas.Dx()*canvas.Dy())
}

// DecodeAll 必须先受限：扫描结构块，不解压图片，限制帧数与累计画布像素。
func gifSamplingWithinBudget(data []byte, width, height int) bool {
	if len(data) < 13 || !(string(data[:6]) == "GIF87a" || string(data[:6]) == "GIF89a") ||
		int(binary.LittleEndian.Uint16(data[6:8])) != width || int(binary.LittleEndian.Uint16(data[8:10])) != height {
		return false
	}
	pos := 13
	if data[10]&0x80 != 0 {
		pos += 3 * (1 << (uint(data[10]&7) + 1))
	}
	if pos > len(data) {
		return false
	}
	skipBlocks := func() bool {
		for pos < len(data) {
			size := int(data[pos])
			pos++
			if size == 0 {
				return true
			}
			if size > len(data)-pos {
				return false
			}
			pos += size
		}
		return false
	}
	frames := 0
	for pos < len(data) {
		marker := data[pos]
		pos++
		switch marker {
		case 0x3b:
			return frames > 1
		case 0x21:
			if pos >= len(data) {
				return false
			}
			pos++ // extension label
			if !skipBlocks() {
				return false
			}
		case 0x2c:
			if len(data)-pos < 9 {
				return false
			}
			x := int(binary.LittleEndian.Uint16(data[pos : pos+2]))
			y := int(binary.LittleEndian.Uint16(data[pos+2 : pos+4]))
			w := int(binary.LittleEndian.Uint16(data[pos+4 : pos+6]))
			h := int(binary.LittleEndian.Uint16(data[pos+6 : pos+8]))
			packed := data[pos+8]
			pos += 9
			frames++
			if w < 1 || h < 1 || x+w > width || y+h > height || frames > 64 || int64(width)*int64(height)*int64(frames) > 16_000_000 {
				return false
			}
			if packed&0x80 != 0 {
				pos += 3 * (1 << (uint(packed&7) + 1))
			}
			if pos > len(data) {
				return false
			}
			if pos >= len(data) {
				return false
			}
			pos++ // LZW minimum code size
			if !skipBlocks() {
				return false
			}
		default:
			return false
		}
	}
	return false
}
