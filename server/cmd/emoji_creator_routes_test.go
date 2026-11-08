package main

import (
	"bytes"
	"context"
	"encoding/json"
	"image"
	"image/color"
	"image/png"
	"strings"
	"testing"

	"github.com/stretchr/testify/require"
	"shenliyuan/internal/models"
	"shenliyuan/internal/services"
)

func TestEmojiPackMediaSelectionAndMetadataIdempotency(t *testing.T) {
	f := newEmojiPackRoutesFixture(t)
	blue := image.NewRGBA(image.Rect(0, 0, 300, 180))
	for y := 0; y < 180; y++ {
		for x := 0; x < 300; x++ {
			blue.SetRGBA(x, y, color.RGBA{0, 0, 255, 255})
		}
	}
	var encoded bytes.Buffer
	require.NoError(t, png.Encode(&encoded, blue))
	service := services.NewEmojiPackService(f.db, f.dir)
	images := []services.EmojiPackUploadImage{{Name: "透明图", Bytes: f.png}, {Name: "蓝色图", Bytes: encoded.Bytes()}}
	options := services.EmojiPackSubmissionOptions{CoverIndex: 1, IconIndex: 0, Tags: []string{"校园"}}
	pack, err := service.Submit(context.Background(), 1, strings.Repeat("m", 16), "封面选择", "", images, options)
	require.NoError(t, err)
	options.CoverIndex = 0
	_, err = service.Submit(context.Background(), 1, strings.Repeat("m", 16), "封面选择", "", images, options)
	require.ErrorIs(t, err, services.ErrEmojiPackConflict)
	require.Equal(t, 200, f.review(pack.ID, "approve", "", 3).Code)
	base := "/api/emoji/packs/" + pack.ID
	cover := f.request("GET", base+"/cover", 0, nil, nil)
	decoded, err := png.Decode(bytes.NewReader(cover.Body.Bytes()))
	require.NoError(t, err)
	require.Equal(t, 300, decoded.Bounds().Dx())
	_, _, b, _ := decoded.At(0, 0).RGBA()
	require.Greater(t, b, uint32(60000))
	icon := f.request("GET", base+"/cover?variant=icon", 0, nil, nil)
	decoded, err = png.Decode(bytes.NewReader(icon.Body.Bytes()))
	require.NoError(t, err)
	require.Equal(t, 3, decoded.Bounds().Dx())
	thumb := f.request("GET", base+"/assets/image-2?variant=thumbnail", 0, nil, nil)
	decoded, err = png.Decode(bytes.NewReader(thumb.Body.Bytes()))
	require.NoError(t, err)
	require.Equal(t, 256, decoded.Bounds().Dx())
}

func TestEmojiPackLegacyVersionMigrationKeepsManifest(t *testing.T) {
	f := newEmojiPackRoutesFixture(t)
	pack := emojiPackResponse(t, f.upload(t, 1, strings.Repeat("n", 16), "升级前的包", "true", f.png))
	require.Equal(t, 200, f.review(pack.ID, "approve", "", 3).Code)
	before := f.request("GET", "/api/emoji/packs/"+pack.ID+"/manifest?version=1", 0, nil, nil).Body.String()
	require.NoError(t, f.db.Migrator().DropIndex(&models.CommunityEmojiPack{}, "idx_community_emoji_packs_family_id"))
	require.NoError(t, f.db.Migrator().DropColumn(&models.CommunityEmojiPack{}, "FamilyID"))
	require.NoError(t, f.db.Migrator().DropColumn(&models.CommunityEmojiPack{}, "Version"))
	for i := 0; i < 2; i++ {
		require.NoError(t, f.db.AutoMigrate(&models.CommunityEmojiPack{}))
	}
	response := f.request("GET", "/api/emoji/packs/"+pack.ID+"/manifest?version=1", 0, nil, nil)
	require.Equal(t, 200, response.Code, response.Body.String())
	require.Equal(t, before, response.Body.String())
}

func TestEmojiCreatorApplicationPermissionAndRevocation(t *testing.T) {
	f := newEmojiPackRoutesFixture(t)
	require.NoError(t, f.db.Delete(&models.EmojiCreator{}, "user_id = ?", 1).Error)
	require.Contains(t, f.request("GET", "/api/emoji/creator", 1, nil, nil).Body.String(), `"status":"none"`)
	require.Equal(t, 403, f.upload(t, 1, strings.Repeat("g", 16), "自用不能直接上架", "true", f.png).Code)
	apply := func(description string, version int) int {
		body, _ := json.Marshal(map[string]any{"description": description, "version": version, "rights_confirmed": true})
		return f.request("POST", "/api/emoji/creator", 1, bytes.NewReader(body), map[string]string{"Content-Type": "application/json"}).Code
	}
	require.Equal(t, 200, apply("原创校园日常表情", 0))
	require.Equal(t, 200, apply("原创校园日常表情", 0))
	require.Equal(t, 409, apply("在审核中更换申请", 1))
	review := func(user uint, version int, action, reason string) int {
		body, _ := json.Marshal(map[string]any{"version": version, "action": action, "reason": reason})
		return f.request("POST", "/api/admin/emoji-creators/1/review", user, bytes.NewReader(body), map[string]string{"Content-Type": "application/json"}).Code
	}
	require.Equal(t, 403, review(1, 1, "approve", ""))
	require.Equal(t, 200, review(3, 1, "approve", ""))
	require.Equal(t, 409, review(3, 1, "reject", "旧审核不能覆盖新状态"))
	pack := emojiPackResponse(t, f.upload(t, 1, strings.Repeat("g", 16), "已开通创作者", "true", f.png))
	require.Equal(t, 400, review(3, 2, "suspend", ""))
	require.Equal(t, 200, review(3, 2, "suspend", "请补充分享授权"))
	require.Equal(t, 403, f.upload(t, 1, strings.Repeat("h", 16), "暂停后投稿", "true", f.png).Code)
	require.Equal(t, 403, f.review(pack.ID, "approve", "", 3).Code)
	require.Equal(t, 200, f.request("GET", "/api/emoji/submissions/"+pack.ID, 1, nil, nil).Code)
	require.Equal(t, 200, apply("补充授权说明后申请恢复", 3))
	require.Equal(t, 200, review(3, 4, "approve", ""))
	require.Equal(t, 200, f.review(pack.ID, "approve", "", 3).Code)
	require.NoError(t, f.db.Model(&models.User{}).Where("id = ?", 3).Update("role", models.RoleUser).Error)
	require.Equal(t, 403, f.request("GET", "/api/admin/emoji-creators", 3, nil, nil).Code)
}

func TestEmojiPackVersionsAndPrivateDerivedMedia(t *testing.T) {
	f := newEmojiPackRoutesFixture(t)
	first := emojiPackResponse(t, f.upload(t, 1, strings.Repeat("i", 16), "第一版", "true", f.png))
	privateURL := "/api/emoji/submissions/" + first.ID + "/assets/image-1?variant=thumbnail"
	require.Equal(t, 404, f.request("GET", privateURL, 2, nil, nil).Code)
	thumb := f.request("GET", privateURL, 1, nil, nil)
	require.Equal(t, 200, thumb.Code)
	require.Equal(t, "private, no-store", thumb.Header().Get("Cache-Control"))
	_, err := png.Decode(bytes.NewReader(thumb.Body.Bytes()))
	require.NoError(t, err)
	publicBase := "/api/emoji/packs/" + first.ID
	require.Equal(t, 404, f.request("GET", publicBase+"/cover", 0, nil, nil).Code)
	require.Equal(t, 200, f.review(first.ID, "approve", "", 3).Code)
	service := services.NewEmojiPackService(f.db, f.dir)
	second, err := service.Submit(context.Background(), 1, strings.Repeat("j", 16), "第二版", "新版简介", []services.EmojiPackUploadImage{{Name: "新的对应文字", Bytes: f.png}}, services.EmojiPackSubmissionOptions{FamilyID: first.ID, Tags: []string{"校园"}})
	require.NoError(t, err)
	require.Equal(t, 2, second.Version)
	require.Equal(t, first.ID, second.FamilyID)
	require.Contains(t, f.request("GET", publicBase, 0, nil, nil).Body.String(), "第一版")
	require.Equal(t, 404, f.request("GET", publicBase+"/manifest?version=2", 0, nil, nil).Code)
	require.Equal(t, 200, f.review(second.ID, "approve", "", 3).Code)
	require.Contains(t, f.request("GET", publicBase, 0, nil, nil).Body.String(), "第二版")
	for _, version := range []string{"1", "2"} {
		require.Equal(t, 200, f.request("GET", publicBase+"/manifest?version="+version, 0, nil, nil).Code)
		require.Equal(t, 200, f.request("GET", publicBase+"/assets/image-1?version="+version+"&variant=thumbnail", 0, nil, nil).Code)
		require.Equal(t, 200, f.request("GET", publicBase+"/cover?version="+version+"&variant=icon", 0, nil, nil).Code)
	}
	require.Equal(t, 200, f.review(second.ID, "unpublish", "整包停止公开下载", 3).Code)
	for _, path := range []string{"/manifest?version=1", "/manifest?version=2", "/assets/image-1?variant=thumbnail", "/cover?variant=icon"} {
		require.Equal(t, 404, f.request("GET", publicBase+path, 0, nil, nil).Code)
	}
	require.Equal(t, 200, f.request("GET", "/api/emoji/submissions/"+second.ID+"/cover", 1, nil, nil).Code)
}
