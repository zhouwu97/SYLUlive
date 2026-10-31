package community

import (
	"context"
	"crypto/sha256"
	"encoding/base64"
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
	Sort            string `json:"sort"`
	Cursor          string `json:"cursor"`
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

// 仅选择允许公开的列；作者和图片使用独立列白名单查询，不预载完整 User/File。
const communityPostColumns = "id, author_id, title, content, board_id, post_type, content_kind, status, revision, created_at, like_count, reply_count"
const communityReplyColumns = "id, author_id, post_id, parent_reply_id, reply_to_reply_id, content, sticker_id, status, created_at, like_count"

// 排名游标只定位公开列表，不提供授权；查询条件变化时拒绝沿用。
var ErrInvalidReadOptions = errors.New("invalid_read_options")

type rankCursor struct {
	Sort  string `json:"sort"`
	Score int    `json:"score"`
	ID    uint   `json:"id"`
	Scope string `json:"scope"`
}

func ValidateOptions(input Request) error {
	if input.Sort != "" && input.Sort != "newest" && input.Sort != "likes" && input.Sort != "replies" {
		return ErrInvalidReadOptions
	}
	if len(input.Cursor) > 512 || (input.Cursor != "" && (input.Sort == "" || input.Sort == "newest")) || (input.Sort != "" && input.Sort != "newest" && input.AfterID != 0) {
		return ErrInvalidReadOptions
	}
	return nil
}

type PublicAuthor struct {
	Nickname string `json:"nickname"`
}
type PublicImage struct {
	Index    int    `json:"index"`
	URL      string `json:"url"`
	MimeType string `json:"mime_type"`
	Width    int    `json:"width"`
	Height   int    `json:"height"`
}

func VisiblePosts(db *gorm.DB) *gorm.DB {
	return db.Model(&models.Post{}).Where("board_id = ? AND status = ? AND content_kind = ?", models.BoardShuitie, models.PostStatusNormal, models.PostContentKindNormal)
}

func ReadPostModel(ctx context.Context, db *gorm.DB, id uint) (models.Post, error) {
	var post models.Post
	err := VisiblePosts(db.WithContext(ctx)).Select(communityPostColumns).Where("id = ?", id).Take(&post).Error
	return post, err
}

type PostView struct {
	PostID        uint          `json:"post_id"`
	Title         string        `json:"title"`
	Content       string        `json:"content"`
	PostType      string        `json:"post_type"`
	Revision      int           `json:"revision"`
	SourceVersion string        `json:"source_version"`
	Status        string        `json:"status"`
	Truncated     bool          `json:"truncated"`
	CreatedAt     time.Time     `json:"created_at"`
	Author        *PublicAuthor `json:"author,omitempty"`
	LikeCount     int           `json:"like_count"`
	ReplyCount    int           `json:"reply_count"`
	Images        []PublicImage `json:"images"`
}

type ReplyView struct {
	ReplyID        uint          `json:"reply_id"`
	PostID         uint          `json:"post_id"`
	ParentReplyID  *uint         `json:"parent_reply_id,omitempty"`
	ReplyToReplyID *uint         `json:"reply_to_reply_id,omitempty"`
	Content        string        `json:"content"`
	StickerID      *string       `json:"sticker_id,omitempty"`
	SourceVersion  string        `json:"source_version"`
	Status         string        `json:"status"`
	Truncated      bool          `json:"truncated"`
	CreatedAt      time.Time     `json:"created_at"`
	Author         *PublicAuthor `json:"author,omitempty"`
	LikeCount      int           `json:"like_count"`
	Images         []PublicImage `json:"images,omitempty"`
}

func contentVersion(value interface{}) string {
	raw, _ := json.Marshal(value)
	hash := sha256.Sum256(raw)
	return hex.EncodeToString(hash[:])
}

func PostDTO(post models.Post, maxRunes int) PostView {
	// 版本不含浏览、点赞、回复数或 UpdatedAt；统计变化不使未来草稿失效。
	version := contentVersion([]interface{}{post.ID, post.Title, post.Content, post.BoardID, post.PostType, post.ContentKind, post.Status, post.Revision})
	return PostView{PostID: post.ID, Title: post.Title, Content: truncateText(post.Content, maxRunes), PostType: post.PostType, Revision: post.Revision, SourceVersion: version, Status: string(post.Status), Truncated: len([]rune(post.Content)) > maxRunes, CreatedAt: post.CreatedAt, LikeCount: post.LikeCount, ReplyCount: post.ReplyCount, Images: []PublicImage{}}
}

func ReplyDTO(reply models.Reply) ReplyView {
	if reply.Status != models.ReplyStatusNormal {
		// 删除后的正文、表情与精确回复目标均不得进入工具结果或其内容哈希。
		return ReplyView{ReplyID: reply.ID, PostID: reply.PostID, Status: "deleted", SourceVersion: contentVersion([]interface{}{reply.ID, reply.PostID, "deleted"})}
	}
	version := contentVersion([]interface{}{reply.ID, reply.PostID, reply.ParentReplyID, reply.ReplyToReplyID, reply.Content, reply.StickerID, reply.Status})
	return ReplyView{ReplyID: reply.ID, PostID: reply.PostID, ParentReplyID: reply.ParentReplyID, ReplyToReplyID: reply.ReplyToReplyID, Content: truncateText(reply.Content, 2000), StickerID: reply.StickerID, SourceVersion: version, Status: string(reply.Status), Truncated: len([]rune(reply.Content)) > 2000, CreatedAt: reply.CreatedAt, LikeCount: reply.LikeCount}
}

func publicAuthors(db *gorm.DB, ids []uint) (map[uint]*PublicAuthor, error) {
	var users []models.User
	if err := db.Select("id, nickname, account_status").Where("id IN ?", ids).Find(&users).Error; err != nil {
		return nil, err
	}
	result := map[uint]*PublicAuthor{}
	for _, user := range users {
		name := strings.TrimSpace(user.Nickname)
		if user.AccountStatus == "cancelled" {
			name = "已注销用户"
		}
		if name == "" {
			name = "未知用户"
		}
		result[user.ID] = &PublicAuthor{Nickname: name}
	}
	return result, nil
}

func publicImages(db *gorm.DB, kind string, ids []uint) (map[uint][]PublicImage, error) {
	table, column := "post_images", "post_id"
	if kind == "reply" {
		table, column = "reply_images", "reply_id"
	}
	var rows []struct {
		ParentID uint
		Path     string
		MimeType string
		Width    int
		Height   int
	}
	err := db.Table(table+" AS i").Select("i."+column+" AS parent_id, f.path, f.mime_type, f.width, f.height").Joins("JOIN files f ON f.id = i.file_id").Where("i."+column+" IN ? AND f.access_scope = ? AND f.status = ?", ids, models.FileAccessPublic, models.FileStatusActive).Order("i.sort_order ASC, i.id ASC").Scan(&rows).Error
	result := map[uint][]PublicImage{}
	for _, row := range rows {
		// 只允许本站已公开的上传资源，不给工具任意 URL、私有文件或磁盘路径。
		if !strings.HasPrefix(row.Path, "/uploads/") || strings.ContainsAny(row.Path, "\\?#%") || strings.Contains(row.Path, "..") || !strings.HasPrefix(row.MimeType, "image/") {
			continue
		}
		result[row.ParentID] = append(result[row.ParentID], PublicImage{Index: len(result[row.ParentID]) + 1, URL: row.Path, MimeType: row.MimeType, Width: row.Width, Height: row.Height})
	}
	return result, err
}

func postViews(db *gorm.DB, posts []models.Post, maxRunes int) ([]PostView, error) {
	ids, authors := []uint{}, []uint{}
	for _, p := range posts {
		ids = append(ids, p.ID)
		authors = append(authors, p.AuthorID)
	}
	names, err := publicAuthors(db, authors)
	if err != nil {
		return nil, err
	}
	images, err := publicImages(db, "post", ids)
	if err != nil {
		return nil, err
	}
	items := make([]PostView, 0, len(posts))
	for _, p := range posts {
		item := PostDTO(p, maxRunes)
		item.Author = names[p.AuthorID]
		if images[p.ID] != nil {
			item.Images = images[p.ID]
		}
		items = append(items, item)
	}
	return items, nil
}

func replyViews(db *gorm.DB, replies []models.Reply) ([]ReplyView, error) {
	ids, authors := []uint{}, []uint{}
	for _, r := range replies {
		if r.Status == models.ReplyStatusNormal {
			ids = append(ids, r.ID)
			authors = append(authors, r.AuthorID)
		}
	}
	names, err := publicAuthors(db, authors)
	if err != nil {
		return nil, err
	}
	images, err := publicImages(db, "reply", ids)
	if err != nil {
		return nil, err
	}
	items := make([]ReplyView, 0, len(replies))
	for _, r := range replies {
		item := ReplyDTO(r)
		if r.Status == models.ReplyStatusNormal {
			item.Author = names[r.AuthorID]
			item.Images = images[r.ID]
		}
		items = append(items, item)
	}
	return items, nil
}

func (reader *Reader) Read(ctx context.Context, name string, input Request) (interface{}, error) {
	if input.Limit == 0 {
		input.Limit = 10
	}
	if input.Limit < 1 || input.Limit > 20 {
		return nil, ErrInvalidReadOptions
	}
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
		if err := ValidateOptions(input); err != nil {
			return nil, err
		}
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
		order := "id DESC"
		ranked := input.Sort == "likes" || input.Sort == "replies"
		column := "like_count"
		if input.Sort == "replies" {
			column = "reply_count"
		}
		scope := contentVersion([]interface{}{input.Query, input.InternalOwnerID})
		if ranked {
			order = column + " DESC, id DESC"
			if input.Cursor != "" {
				var cursor rankCursor
				raw, err := base64.RawURLEncoding.DecodeString(input.Cursor)
				if err != nil || json.Unmarshal(raw, &cursor) != nil || cursor.Sort != input.Sort || cursor.ID == 0 || cursor.Score < 0 || cursor.Scope != scope {
					return nil, ErrInvalidReadOptions
				}
				query = query.Where("("+column+" < ? OR ("+column+" = ? AND id < ?))", cursor.Score, cursor.Score, cursor.ID)
			}
		}
		var posts []models.Post
		if err := query.Order(order).Limit(input.Limit + 1).Find(&posts).Error; err != nil {
			return nil, err
		}
		more := len(posts) > input.Limit
		if more {
			posts = posts[:input.Limit]
		}
		items, err := postViews(db, posts, 600)
		if err != nil {
			return nil, err
		}
		next := uint(0)
		nextCursor := ""
		if more {
			last := posts[len(posts)-1]
			if ranked {
				score := last.LikeCount
				if input.Sort == "replies" {
					score = last.ReplyCount
				}
				raw, _ := json.Marshal(rankCursor{Sort: input.Sort, Score: score, ID: last.ID, Scope: scope})
				nextCursor = base64.RawURLEncoding.EncodeToString(raw)
			} else {
				next = last.ID
			}
		}
		mode := input.Sort
		if mode == "" {
			mode = "newest"
		}
		return map[string]interface{}{"items": items, "next_after_id": next, "next_cursor": nextCursor, "sort": mode}, nil
	case "community.get_post":
		post, err := ReadPostModel(ctx, db, input.PostID)
		if err != nil {
			return nil, err
		}
		items, err := postViews(db, []models.Post{post}, 10000)
		if err != nil {
			return nil, err
		}
		return items[0], nil
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
		more := len(replies) > input.Limit
		if more {
			replies = replies[:input.Limit]
		}
		items, err := replyViews(db, replies)
		if err != nil {
			return nil, err
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
		posts, err := postViews(db, []models.Post{post}, 10000)
		if err != nil {
			return nil, err
		}
		data := map[string]interface{}{"post": posts[0]}
		thread := []models.Reply{reply}
		if reply.ParentReplyID != nil {
			var root models.Reply
			if err := db.Select(communityReplyColumns).Where("id = ? AND post_id = ? AND parent_reply_id IS NULL", *reply.ParentReplyID, reply.PostID).Take(&root).Error; err != nil {
				return nil, err
			}
			thread = append(thread, root)
			if reply.ReplyToReplyID != nil && *reply.ReplyToReplyID != root.ID {
				var target models.Reply
				if err := db.Select(communityReplyColumns).
					Where("id = ? AND post_id = ? AND parent_reply_id = ?", *reply.ReplyToReplyID, reply.PostID, root.ID).
					Take(&target).Error; err != nil {
					return nil, err
				}
				thread = append(thread, target)
			}
		}
		views, err := replyViews(db, thread)
		if err != nil {
			return nil, err
		}
		data["reply"] = views[0]
		if len(views) > 1 {
			data["root_reply"] = views[1]
		}
		if len(views) > 2 {
			data["target_reply"] = views[2]
		}
		return data, nil
	default:
		return nil, errors.New("unknown_community_tool")
	}
}
