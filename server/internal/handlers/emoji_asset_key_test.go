package handlers

import (
	"net/http"
	"net/url"
	"strings"
	"testing"

	"github.com/gin-gonic/gin"
	"gorm.io/gorm"

	"shenliyuan/internal/models"
)

func TestValidateEmojiAssetReferenceAcceptsClientKeys(t *testing.T) {
	cases := []struct {
		name    string
		key     string
		packID  string
		hasPack bool
	}{
		{name: "unicode", key: "unicode:😀"},
		{name: "内置贴图", key: "builtin:test:a", packID: "test", hasPack: true},
		{name: "私有文件", key: "private:file-12"},
		{name: "私有 URL 身份", key: "private:url-" + strings.Repeat("a", 64)},
		{
			name:    "本地随机包",
			key:     "local:local-" + strings.Repeat("f", 32) + ":a",
			packID:  "local-" + strings.Repeat("f", 32),
			hasPack: true,
		},
		{name: "带包身份的私有资源", key: "private:server-pack:asset", packID: "server-pack", hasPack: true},
		{name: "资源标识含空格", key: "builtin:test:my pack", packID: "test", hasPack: true},
	}
	for _, item := range cases {
		t.Run(item.name, func(t *testing.T) {
			var packID *string
			if item.hasPack {
				packID = strPtr(item.packID)
			}
			if err := validateEmojiAssetReference(strPtr(item.key), packID); err != nil {
				t.Fatalf("合法资源键被拒绝 %q: %v", item.key, err)
			}
		})
	}
	t.Run("官方目录内的资源", func(t *testing.T) {
		for _, pack := range officialEmojiPacks {
			for assetID := range pack.assets {
				key := "official:" + pack.ID + ":" + assetID
				if err := validateEmojiAssetReference(strPtr(key), strPtr(pack.ID)); err != nil {
					t.Fatalf("已发布资源被拒绝 %q: %v", key, err)
				}
				return
			}
		}
		t.Fatal("官方目录没有可用于校验的资源")
	})
	t.Run("缺少 asset_key 时不校验 pack_id", func(t *testing.T) {
		if err := validateEmojiAssetReference(nil, strPtr("anything")); err != nil {
			t.Fatalf("旧客户端流量被拒绝: %v", err)
		}
	})
}

func TestValidateEmojiAssetReferenceRejectsSpoofedIdentity(t *testing.T) {
	official := officialEmojiPacks[0]
	var officialAsset string
	for assetID := range official.assets {
		officialAsset = assetID
		break
	}
	cases := []struct {
		name   string
		key    string
		packID *string
	}{
		{name: "命名空间未知", key: "pack:x:a"},
		{name: "分段过少", key: "builtin"},
		{name: "分段过多", key: "official:pack:asset:extra"},
		{name: "空包身份", key: "builtin::a"},
		{name: "缺少包身份", key: "local:asset"},
		{name: "Unicode 带包身份", key: "unicode:pack:😀", packID: strPtr("pack")},
		{name: "pack_id 与键不一致", key: "builtin:test:a", packID: strPtr("victim")},
		{name: "pack_id 缺失", key: "builtin:test:a"},
		{name: "官方包不存在", key: "official:not-published:" + officialAsset, packID: strPtr("not-published")},
		{name: "官方资源不存在", key: "official:" + official.ID + ":not-published", packID: strPtr(official.ID)},
		{name: "控制字符", key: "builtin:test:a\nfake", packID: strPtr("test")},
		{name: "首尾空白", key: "builtin:test: a", packID: strPtr("test")},
		{name: "包标识过长", key: "builtin:" + strings.Repeat("a", 129) + ":a", packID: strPtr(strings.Repeat("a", 129))},
		{name: "键过长", key: "builtin:test:" + strings.Repeat("b", 512)},
	}
	for _, item := range cases {
		t.Run(item.name, func(t *testing.T) {
			if err := validateEmojiAssetReference(strPtr(item.key), item.packID); err == nil {
				t.Fatalf("伪造身份未被拒绝: %q", item.key)
			}
		})
	}
}

func TestMessageSendRejectsSpoofedEmojiIdentity(t *testing.T) {
	db := newMessageTestDB(t)
	createMessageTestUser(t, db, 1, "Alice")
	createMessageTestUser(t, db, 2, "Bob")
	handler := NewMessageHandler(db)

	response := performMessageRequest(
		t, handler.Send, http.MethodPost, "/api/messages/2",
		gin.Params{{Key: "user_id", Value: "2"}}, 1,
		`{"content":"看我的","asset_key":"builtin:test:a","pack_id":"victim"}`,
	)
	if response.Code != http.StatusBadRequest {
		t.Fatalf("status=%d body=%s", response.Code, response.Body.String())
	}
	assertNoEmojiRows(t, db, &models.Message{})
}

func TestReplyCreateRejectsSpoofedEmojiIdentity(t *testing.T) {
	db := newReplyTestDB(t)
	post := createReplyTestPost(t, db)
	handler := NewReplyHandler(db, "", "")

	response := performReplyRequest(t, handler.Create, post.ID, url.Values{
		"content":   {"看我的"},
		"asset_key": {"official:" + officialEmojiPacks[0].ID + ":not-published"},
		"pack_id":   {officialEmojiPacks[0].ID},
	})
	if response.Code != http.StatusBadRequest {
		t.Fatalf("status=%d body=%s", response.Code, response.Body.String())
	}
	assertNoEmojiRows(t, db, &models.Reply{})
}

func assertNoEmojiRows(t *testing.T, db *gorm.DB, target any) {
	t.Helper()
	var rows int64
	if err := db.Model(target).Count(&rows).Error; err != nil {
		t.Fatal(err)
	}
	if rows != 0 {
		t.Fatalf("被拒绝的内容仍然入库: %d 行", rows)
	}
}
