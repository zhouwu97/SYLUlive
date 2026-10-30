package community

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"gorm.io/gorm"
	"shenliyuan/internal/models"
	"sort"
	"strings"
	"time"
)

type Sticker struct {
	ID    string `json:"sticker_id"`
	Label string `json:"label"`
}

type Request struct {
	InternalOwnerID uint   `json:"-"` // 仅由已验证的服务端上下文设置。
	PostID          uint   `json:"post_id"`
	ReplyID         uint   `json:"reply_id"`
	AfterID         uint   `json:"after_id"`
	Limit           int    `json:"limit"`
	Query           string `json:"query"`
	AfterStickerID  string `json:"after_sticker_id"`
}

type Reader struct {
	db       *gorm.DB
	stickers []Sticker
}

func NewReader(db *gorm.DB, stickers []Sticker) *Reader {
	items := append([]Sticker{}, stickers...)
	sort.Slice(items, func(i, j int) bool { return items[i].ID < items[j].ID })
	return &Reader{db: db, stickers: items}
}

func truncateText(value string, maxRunes int) string {
	value = strings.TrimSpace(value)
	runes := []rune(value)
	if len(runes) <= maxRunes {
		return value
	}
	return string(runes[:maxRunes]) + "..."
}

// 仅选择模型允许接收的列。不要预载 User、联系方式、治理备注或上传资源。
const communityPostColumns = "id, title, content, board_id, post_type, content_kind, status, revision, created_at"
const communityReplyColumns = "id, post_id, parent_reply_id, reply_to_reply_id, content, sticker_id, status, created_at"

func VisiblePosts(db *gorm.DB) *gorm.DB {
	return db.Model(&models.Post{}).Where("board_id = ? AND status = ? AND content_kind = ?", models.BoardShuitie, models.PostStatusNormal, models.PostContentKindNormal)
}

func ReadPostModel(ctx context.Context, db *gorm.DB, id uint) (models.Post, error) {
	var post models.Post
	err := VisiblePosts(db.WithContext(ctx)).Select(communityPostColumns).Where("id = ?", id).Take(&post).Error
	return post, err
}

type PostView struct {
	PostID        uint      `json:"post_id"`
	Title         string    `json:"title"`
	Content       string    `json:"content"`
	PostType      string    `json:"post_type"`
	Revision      int       `json:"revision"`
	SourceVersion string    `json:"source_version"`
	Status        string    `json:"status"`
	Truncated     bool      `json:"truncated"`
	CreatedAt     time.Time `json:"created_at"`
}

type ReplyView struct {
	ReplyID        uint      `json:"reply_id"`
	PostID         uint      `json:"post_id"`
	ParentReplyID  *uint     `json:"parent_reply_id,omitempty"`
	ReplyToReplyID *uint     `json:"reply_to_reply_id,omitempty"`
	Content        string    `json:"content"`
	StickerID      *string   `json:"sticker_id,omitempty"`
	SourceVersion  string    `json:"source_version"`
	Status         string    `json:"status"`
	Truncated      bool      `json:"truncated"`
	CreatedAt      time.Time `json:"created_at"`
}

func contentVersion(value interface{}) string {
	raw, _ := json.Marshal(value)
	hash := sha256.Sum256(raw)
	return hex.EncodeToString(hash[:])
}

func PostDTO(post models.Post, maxRunes int) PostView {
	// 版本不含浏览、点赞、回复数或 UpdatedAt；统计变化不使未来草稿失效。
	version := contentVersion([]interface{}{post.ID, post.Title, post.Content, post.BoardID, post.PostType, post.ContentKind, post.Status, post.Revision})
	return PostView{post.ID, post.Title, truncateText(post.Content, maxRunes), post.PostType, post.Revision, version, string(post.Status), len([]rune(post.Content)) > maxRunes, post.CreatedAt}
}

func ReplyDTO(reply models.Reply) ReplyView {
	if reply.Status != models.ReplyStatusNormal {
		// 删除后的正文、表情与精确回复目标均不得进入工具结果或其内容哈希。
		return ReplyView{ReplyID: reply.ID, PostID: reply.PostID, Status: "deleted", SourceVersion: contentVersion([]interface{}{reply.ID, reply.PostID, "deleted"})}
	}
	version := contentVersion([]interface{}{reply.ID, reply.PostID, reply.ParentReplyID, reply.ReplyToReplyID, reply.Content, reply.StickerID, reply.Status})
	return ReplyView{reply.ID, reply.PostID, reply.ParentReplyID, reply.ReplyToReplyID, truncateText(reply.Content, 2000), reply.StickerID, version, string(reply.Status), len([]rune(reply.Content)) > 2000, reply.CreatedAt}
}

func (reader *Reader) Read(ctx context.Context, name string, input Request) (interface{}, error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	if name == "community.list_stickers" {
		items := make([]Sticker, 0)
		query := strings.ToLower(input.Query)
		for _, item := range reader.stickers {
			if item.ID > input.AfterStickerID && strings.Contains(strings.ToLower(item.ID+" "+item.Label), query) {
				items = append(items, item)
			}
			if len(items) > input.Limit {
				break
			}
		}
		next := ""
		if len(items) > input.Limit {
			items = items[:input.Limit]
			next = items[len(items)-1].ID
		}
		return map[string]interface{}{"items": items, "next_after_sticker_id": next}, nil
	}
	if reader.db == nil {
		return nil, errors.New("mcp_not_configured")
	}
	db := reader.db.WithContext(ctx)
	switch name {
	case "community.list_feed", "community.search_posts":
		query := VisiblePosts(db).Select(communityPostColumns)
		if input.InternalOwnerID != 0 {
			query = query.Where("author_id = ?", input.InternalOwnerID)
		}
		if input.AfterID != 0 {
			query = query.Where("id < ?", input.AfterID)
		}
		if name == "community.search_posts" {
			// 转义 LIKE 通配符，避免用户输入的 % 或 _ 被解释为全量匹配。
			pattern := "%" + strings.NewReplacer("!", "!!", "%", "!%", "_", "!_").Replace(strings.ToLower(input.Query)) + "%"
			query = query.Where("(LOWER(title) LIKE ? ESCAPE '!' OR LOWER(content) LIKE ? ESCAPE '!')", pattern, pattern)
		}
		var posts []models.Post
		if err := query.Order("id DESC").Limit(input.Limit + 1).Find(&posts).Error; err != nil {
			return nil, err
		}
		items := make([]PostView, 0, input.Limit)
		more := len(posts) > input.Limit
		if more {
			posts = posts[:input.Limit]
		}
		for _, post := range posts {
			items = append(items, PostDTO(post, 600))
		}
		next := uint(0)
		if more {
			next = posts[len(posts)-1].ID
		}
		return map[string]interface{}{"items": items, "next_after_id": next}, nil
	case "community.get_post":
		post, err := ReadPostModel(ctx, db, input.PostID)
		if err != nil {
			return nil, err
		}
		return PostDTO(post, 6000), nil
	case "community.list_replies":
		// 同一查询复核父帖状态，避免仅验证页面上下文后直接读取已隐藏帖的评论。
		var replies []models.Reply
		err := db.Model(&models.Reply{}).Select(communityReplyColumns).
			Where("post_id = ? AND status = ? AND id > ?", input.PostID, models.ReplyStatusNormal, input.AfterID).
			Where("post_id IN (?)", VisiblePosts(db).Select("id")).
			Order("id ASC").Limit(input.Limit + 1).Find(&replies).Error
		if err != nil {
			return nil, err
		}
		if _, err := ReadPostModel(ctx, db, input.PostID); err != nil {
			return nil, err
		}
		items := make([]ReplyView, 0, input.Limit)
		more := len(replies) > input.Limit
		if more {
			replies = replies[:input.Limit]
		}
		for _, reply := range replies {
			items = append(items, ReplyDTO(reply))
		}
		next := uint(0)
		if more {
			next = replies[len(replies)-1].ID
		}
		return map[string]interface{}{"items": items, "next_after_id": next}, nil
	case "community.get_reply_context":
		var reply models.Reply
		if err := db.Select(communityReplyColumns).Where("id = ? AND status = ?", input.ReplyID, models.ReplyStatusNormal).Take(&reply).Error; err != nil {
			return nil, err
		}
		post, err := ReadPostModel(ctx, db, reply.PostID)
		if err != nil {
			return nil, err
		}
		data := map[string]interface{}{"post": PostDTO(post, 6000), "reply": ReplyDTO(reply)}
		if reply.ParentReplyID != nil {
			var root models.Reply
			if err := db.Select(communityReplyColumns).Where("id = ? AND post_id = ? AND parent_reply_id IS NULL", *reply.ParentReplyID, reply.PostID).Take(&root).Error; err != nil {
				return nil, err
			}
			data["root_reply"] = ReplyDTO(root)
			if reply.ReplyToReplyID != nil && *reply.ReplyToReplyID != root.ID {
				var target models.Reply
				if err := db.Select(communityReplyColumns).
					Where("id = ? AND post_id = ? AND parent_reply_id = ?", *reply.ReplyToReplyID, reply.PostID, root.ID).
					Take(&target).Error; err != nil {
					return nil, err
				}
				data["target_reply"] = ReplyDTO(target)
			}
		}
		return data, nil
	default:
		return nil, errors.New("unknown_community_tool")
	}
}
