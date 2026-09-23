package services

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"math"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	"shenliyuan/internal/models"

	"gorm.io/gorm"
	"gorm.io/gorm/clause"
)

const (
	PollCodeNotFound           = "poll_not_found"
	PollCodeEnded              = "poll_ended"
	PollCodeDeleted            = "poll_deleted"
	PollCodeRulesLocked        = "poll_rules_locked"
	PollCodeChangeDisabled     = "poll_change_disabled"
	PollCodeInvalidOption      = "invalid_poll_option"
	PollCodeInvalidChoiceCount = "invalid_poll_choice_count"
	PollCodeCreationLimit      = "poll_creation_limit"
	PollCodePermissionDenied   = "poll_permission_denied"
	PollCodeInvalidInput       = "invalid_poll_input"
	// PollCodeServiceUnavailable 表示共享发布额度暂时无法判定（计数查询失败）。
	// 与普通发帖一致：不能把"数不出来"当成"零次发布"，也不能报成用户错误。
	PollCodeServiceUnavailable = "poll_service_unavailable"
)

// PollError 为客户端提供稳定错误码，避免依赖中文文案判断状态。
type PollError struct {
	Code    string
	Message string
}

func (e *PollError) Error() string { return e.Message }

func newPollError(code, message string) error {
	return &PollError{Code: code, Message: message}
}

type CreatePollInput struct {
	Title             string    `json:"title"`
	Description       string    `json:"description"`
	Category          string    `json:"category"`
	SelectionMode     string    `json:"selection_mode"`
	MaxChoices        int       `json:"max_choices"`
	ResultsVisibility string    `json:"results_visibility"`
	AllowChange       bool      `json:"allow_change"`
	EndsAt            time.Time `json:"ends_at"`
	Options           []string  `json:"options"`
	FileIDs           []uint    `json:"file_ids"`
}

type PollListInput struct {
	Sort     string
	Category string
	Page     int
	Limit    int
	Scope    string
	UserID   uint
	// Cursor 是上一页返回的 next_cursor。给了它就按 keyset 续页而不是 offset：
	// 并发新增会让 offset 整体位移，同一条投票因此被跳过或重复。
	Cursor string
}

// pollRecommendPoolSize 是推荐排序一次装载的候选池上界：最近的这些投票参与重排。
// 池是有界且可解释的（按发帖时间倒序截取），不是「全量推荐」，所以 total 只按池内条数返回。
const pollRecommendPoolSize = 500

// PollListResult 的字段语义：
//   - total：这一次请求可分页的候选总数。latest/ending 等于全部匹配数；
//     recommend 只等于候选池内条数（池外条目这一路翻不到）。旧客户端只读 total，
//     得到的仍是「翻得到的条数」，不会像改动前那样拿到一个永远翻不完的大数。
//   - matched_total：满足过滤条件的全站匹配数，不随分页变化，用于解释「还有多少没进候选池」。
//   - pool_size：推荐候选池上界；非推荐排序为 0，表示没有池限制。
//   - has_more：服务端按本页之后数据源里是否还有行判断，客户端不必再按「本页等于 limit」猜。
type PollListResult struct {
	Items        []models.Post `json:"items"`
	Page         int           `json:"page"`
	Limit        int           `json:"limit"`
	Total        int64         `json:"total"`
	MatchedTotal int64         `json:"matched_total"`
	PoolSize     int64         `json:"pool_size"`
	HasMore      bool          `json:"has_more"`
	// NextCursor 是续页位置，has_more 为 false 时为空。带 cursor 的链路不依赖 offset，
	// 并发插入不会再让某一条被跳过或重复。
	NextCursor string `json:"next_cursor"`
	// CursorStale 表示给定游标已经不能续页（解析失败、排序变了或位置过期），
	// 本响应实际上是第一页。客户端必须整体替换列表，不能接着往下拼。
	CursorStale bool `json:"cursor_stale"`
}

// PollService 承担投票事务和 DTO 脱敏，Handler 只负责 HTTP 协议转换。
type PollService struct {
	db  *gorm.DB
	now func() time.Time
}

// 投票写入在 SQLite 测试环境需要串行化；生产 PostgreSQL 仍由行锁保证并发安全。
// 使用单一锁避免按投票 ID 累积永久存活的 sync.Map。
var pollWriteLock sync.Mutex

func NewPollService(db *gorm.DB) *PollService {
	return &PollService{db: db, now: time.Now}
}

func (s *PollService) SetNowForTest(now func() time.Time) {
	if now != nil {
		s.now = now
	}
}

func (s *PollService) Create(ctx context.Context, userID uint, role string, input CreatePollInput) (models.Post, error) {
	if userID == 0 {
		return models.Post{}, newPollError(PollCodePermissionDenied, "请先登录")
	}
	input, err := s.validateInput(input, s.now())
	if err != nil {
		return models.Post{}, err
	}
	unlock := s.acquirePollWriteLock()
	defer unlock()

	// 注意：这里不取时间。额度计数窗口的上界是 created_at <= now，时间必须在
	// 拿到用户行锁之后再取，否则等锁期间以更晚时间提交的普通发帖会被旧 now 过滤掉。
	post := models.Post{
		Title:       input.Title,
		Content:     input.Description,
		BoardID:     models.BoardShuitie,
		AuthorID:    userID,
		PostType:    "poll",
		ContentKind: models.PostContentKindPoll,
		Status:      models.PostStatusNormal,
	}
	err = s.db.WithContext(ctx).Transaction(func(tx *gorm.DB) error {
		// PostgreSQL 使用用户行锁把“额度检查 + 创建”串成一个事务；
		// SQLite 由 acquirePollWriteLock 提供同等的测试环境串行语义。
		var user models.User
		if err := tx.Clauses(clause.Locking{Strength: "UPDATE"}).Select("id").First(&user, userID).Error; err != nil {
			return newPollError(PollCodePermissionDenied, "用户不存在")
		}
		// 拿到共享用户行锁之后才取时刻，并让计数窗口上界、CreatedAt、LastActivityAt
		// 使用同一时刻，保证与普通发帖遵循同一套共享额度协议。
		now := s.now()
		post.CreatedAt = now
		post.LastActivityAt = now
		if !isAdminRole(role) {
			// 投票创建同样写入 posts 记录，必须遵守与普通发帖相同的发布额度协议，
			// 否则并发投票可以绕过 5 分钟 / 24 小时发帖额度。
			if err := CheckPostPublishQuota(tx, userID, now); err != nil {
				if errors.Is(err, ErrContentRateLimited) {
					return newPollError(PollCodeCreationLimit, "发帖过于频繁，请稍后再试")
				}
				if errors.Is(err, ErrContentQuotaUnavailable) {
					return newPollError(PollCodeServiceUnavailable, "发布额度暂时无法校验，请稍后再试")
				}
				return err
			}
			if err := s.checkCreationLimit(tx, userID, now); err != nil {
				return err
			}
		}
		if _, err := ValidateImageFileIDs(tx, input.FileIDs, 3, userID); err != nil {
			return err
		}
		if err := ClaimPublicImageFiles(tx, input.FileIDs); err != nil {
			return err
		}
		if err := tx.Create(&post).Error; err != nil {
			return err
		}
		poll := models.Poll{
			PostID:            post.ID,
			Category:          input.Category,
			SelectionMode:     input.SelectionMode,
			MaxChoices:        input.MaxChoices,
			ResultsVisibility: input.ResultsVisibility,
			AllowChange:       input.AllowChange,
			IsAnonymous:       true,
			Status:            models.PollStatusActive,
			EndsAt:            input.EndsAt,
		}
		if err := tx.Create(&poll).Error; err != nil {
			return err
		}
		options := make([]models.PollOption, 0, len(input.Options))
		for i, text := range input.Options {
			options = append(options, models.PollOption{PollID: poll.ID, Text: text, SortOrder: i})
		}
		if err := tx.Create(&options).Error; err != nil {
			return err
		}
		for i, fileID := range input.FileIDs {
			if err := tx.Create(&models.PostImage{PostID: post.ID, FileID: fileID, SortOrder: i}).Error; err != nil {
				return err
			}
		}
		return nil
	})
	if err != nil {
		if errors.Is(err, ErrInvalidImageFileReference) {
			return models.Post{}, newPollError(PollCodeInvalidInput, err.Error())
		}
		return models.Post{}, err
	}

	if awarded, award, awardErr := AwardDailyGlobalExp(s.db, userID, GlobalActionPostDaily, GlobalExpPostDaily, "post", post.ID); awardErr == nil && awarded && award != nil {
		post.ExpAwards = []models.ExpAward{*award}
		post.ExpEarned = award.Exp
	}
	loaded, err := s.GetByPostID(post.ID, userID)
	if err != nil {
		return models.Post{}, err
	}
	loaded.ExpAwards = post.ExpAwards
	loaded.ExpEarned = post.ExpEarned
	return loaded, nil
}

func (s *PollService) Update(pollID, userID uint, role string, input CreatePollInput) (models.Post, error) {
	unlock := s.acquirePollWriteLock()
	defer unlock()

	now := s.now()
	var postID uint
	err := s.db.Transaction(func(tx *gorm.DB) error {
		var poll models.Poll
		if err := tx.Clauses(clause.Locking{Strength: "UPDATE"}).First(&poll, pollID).Error; err != nil {
			return newPollError(PollCodeNotFound, "投票不存在")
		}
		var post models.Post
		if err := tx.Clauses(clause.Locking{Strength: "UPDATE"}).First(&post, poll.PostID).Error; err != nil {
			return newPollError(PollCodeNotFound, "投票不存在")
		}
		if !isPublicPollPostStatus(post.Status) || poll.Status == models.PollStatusDeleted {
			return newPollError(PollCodeDeleted, "投票已删除")
		}
		if post.AuthorID != userID && !isAdminRole(role) {
			return newPollError(PollCodePermissionDenied, "无权编辑该投票")
		}
		if err := validatePollMutableInput(&input); err != nil {
			return err
		}
		if _, err := ValidateImageFileIDs(tx, input.FileIDs, 3, userID); err != nil {
			return newPollError(PollCodeInvalidInput, err.Error())
		}
		if err := ClaimPublicImageFiles(tx, input.FileIDs); err != nil {
			return err
		}
		if effectivePollStatus(poll, post.Status, now) != models.PollStatusActive {
			return newPollError(PollCodeEnded, "投票已结束，不能编辑")
		}

		if poll.ParticipantCount > 0 {
			var options []models.PollOption
			if err := tx.Where("poll_id = ?", poll.ID).Order("sort_order ASC").Find(&options).Error; err != nil {
				return err
			}
			if lockedRulesChanged(post, poll, options, input) {
				return newPollError(PollCodeRulesLocked, "已有用户参与，只能修改补充说明和图片")
			}
		} else {
			validated, err := s.validateInput(input, now)
			if err != nil {
				return err
			}
			input = validated
			if err := tx.Model(&poll).Updates(map[string]interface{}{
				"category": input.Category, "selection_mode": input.SelectionMode,
				"max_choices": input.MaxChoices, "results_visibility": input.ResultsVisibility,
				"allow_change": input.AllowChange, "ends_at": input.EndsAt,
			}).Error; err != nil {
				return err
			}
			if err := tx.Where("poll_id = ?", poll.ID).Delete(&models.PollOption{}).Error; err != nil {
				return err
			}
			options := make([]models.PollOption, 0, len(input.Options))
			for i, text := range input.Options {
				options = append(options, models.PollOption{PollID: poll.ID, Text: text, SortOrder: i})
			}
			if err := tx.Create(&options).Error; err != nil {
				return err
			}
		}
		postUpdates := map[string]interface{}{"content": strings.TrimSpace(input.Description)}
		if poll.ParticipantCount == 0 {
			postUpdates["title"] = input.Title
		}
		if err := tx.Model(&post).Updates(postUpdates).Error; err != nil {
			return err
		}
		if err := replacePostImages(tx, post.ID, input.FileIDs); err != nil {
			return err
		}
		postID = post.ID
		return nil
	})
	if err != nil {
		return models.Post{}, err
	}
	return s.GetByPostID(postID, userID)
}

func (s *PollService) PutBallot(pollID, userID uint, optionIDs []uint) (models.Post, error) {
	if userID == 0 {
		return models.Post{}, newPollError(PollCodePermissionDenied, "请先登录")
	}
	unlock := s.acquirePollWriteLock()
	defer unlock()

	var postID uint
	err := s.db.Transaction(func(tx *gorm.DB) error {
		var poll models.Poll
		if err := tx.Clauses(clause.Locking{Strength: "UPDATE"}).First(&poll, pollID).Error; err != nil {
			return newPollError(PollCodeNotFound, "投票不存在")
		}
		var post models.Post
		if err := tx.Clauses(clause.Locking{Strength: "UPDATE"}).Select("id", "status").First(&post, poll.PostID).Error; err != nil {
			return newPollError(PollCodeNotFound, "投票不存在")
		}
		postID = post.ID
		status := effectivePollStatus(poll, post.Status, s.now())
		if status == models.PollStatusDeleted || !isPublicPollPostStatus(post.Status) {
			return newPollError(PollCodeDeleted, "投票已删除")
		}
		if status != models.PollStatusActive {
			return newPollError(PollCodeEnded, "投票已结束")
		}

		var options []models.PollOption
		if err := tx.Where("poll_id = ?", poll.ID).Order("sort_order ASC").Find(&options).Error; err != nil {
			return err
		}
		unique, err := validateChoiceIDs(poll, options, optionIDs)
		if err != nil {
			return err
		}

		var ballot models.PollBallot
		ballotErr := tx.Clauses(clause.Locking{Strength: "UPDATE"}).Where("poll_id = ? AND user_id = ?", poll.ID, userID).First(&ballot).Error
		hadBallot := ballotErr == nil
		if ballotErr != nil && !errors.Is(ballotErr, gorm.ErrRecordNotFound) {
			return ballotErr
		}
		oldIDs := []uint{}
		if hadBallot {
			var choices []models.PollBallotChoice
			if err := tx.Where("ballot_id = ?", ballot.ID).Find(&choices).Error; err != nil {
				return err
			}
			for _, choice := range choices {
				oldIDs = append(oldIDs, choice.OptionID)
			}
		}
		if sameUintSet(oldIDs, unique) {
			return nil
		}
		if hadBallot && !poll.AllowChange {
			return newPollError(PollCodeChangeDisabled, "该投票不允许修改选择")
		}
		if !hadBallot {
			ballot = models.PollBallot{PollID: poll.ID, UserID: userID}
			if err := tx.Create(&ballot).Error; err != nil {
				return err
			}
		} else if err := tx.Where("ballot_id = ?", ballot.ID).Delete(&models.PollBallotChoice{}).Error; err != nil {
			return err
		}
		for _, optionID := range oldIDs {
			if err := tx.Model(&models.PollOption{}).Where("id = ? AND poll_id = ?", optionID, poll.ID).
				UpdateColumn("vote_count", gorm.Expr("CASE WHEN vote_count > 0 THEN vote_count - 1 ELSE 0 END")).Error; err != nil {
				return err
			}
		}
		choices := make([]models.PollBallotChoice, 0, len(unique))
		for _, optionID := range unique {
			choices = append(choices, models.PollBallotChoice{BallotID: ballot.ID, OptionID: optionID})
		}
		if err := tx.Create(&choices).Error; err != nil {
			return err
		}
		for _, optionID := range unique {
			result := tx.Model(&models.PollOption{}).Where("id = ? AND poll_id = ?", optionID, poll.ID).
				UpdateColumn("vote_count", gorm.Expr("vote_count + 1"))
			if result.Error != nil || result.RowsAffected != 1 {
				return newPollError(PollCodeInvalidOption, "投票选项无效")
			}
		}
		updates := map[string]interface{}{
			"choice_count": gorm.Expr("choice_count + ?", len(unique)-len(oldIDs)),
			"last_vote_at": s.now(),
		}
		if !hadBallot {
			updates["participant_count"] = gorm.Expr("participant_count + 1")
		}
		if err := tx.Model(&poll).Updates(updates).Error; err != nil {
			return err
		}
		return nil
	})
	if err != nil {
		return models.Post{}, err
	}
	return s.GetByPostID(postID, userID)
}

func (s *PollService) Close(pollID, userID uint, role string) (models.Post, error) {
	unlock := s.acquirePollWriteLock()
	defer unlock()
	var postID uint
	err := s.db.Transaction(func(tx *gorm.DB) error {
		var poll models.Poll
		if err := tx.Clauses(clause.Locking{Strength: "UPDATE"}).First(&poll, pollID).Error; err != nil {
			return newPollError(PollCodeNotFound, "投票不存在")
		}
		var post models.Post
		if err := tx.Clauses(clause.Locking{Strength: "UPDATE"}).First(&post, poll.PostID).Error; err != nil {
			return newPollError(PollCodeNotFound, "投票不存在")
		}
		postID = post.ID
		if poll.Status == models.PollStatusDeleted || !isPublicPollPostStatus(post.Status) {
			return newPollError(PollCodeDeleted, "投票已删除")
		}
		if post.AuthorID != userID && !isAdminRole(role) {
			return newPollError(PollCodePermissionDenied, "无权结束该投票")
		}
		if effectivePollStatus(poll, post.Status, s.now()) != models.PollStatusActive {
			return nil
		}
		now := s.now()
		return tx.Model(&poll).Updates(map[string]interface{}{"status": models.PollStatusClosed, "closed_at": &now, "closed_by": userID}).Error
	})
	if err != nil {
		return models.Post{}, err
	}
	return s.GetByPostID(postID, userID)
}

func (s *PollService) Delete(pollID, userID uint, role string) error {
	unlock := s.acquirePollWriteLock()
	defer unlock()
	return s.db.Transaction(func(tx *gorm.DB) error {
		var poll models.Poll
		if err := tx.Clauses(clause.Locking{Strength: "UPDATE"}).First(&poll, pollID).Error; err != nil {
			return newPollError(PollCodeNotFound, "投票不存在")
		}
		var post models.Post
		if err := tx.Clauses(clause.Locking{Strength: "UPDATE"}).First(&post, poll.PostID).Error; err != nil {
			return newPollError(PollCodeNotFound, "投票不存在")
		}
		if post.AuthorID != userID && !isAdminRole(role) {
			return newPollError(PollCodePermissionDenied, "无权删除该投票")
		}
		if err := tx.Model(&poll).Update("status", models.PollStatusDeleted).Error; err != nil {
			return err
		}
		return tx.Model(&post).Update("status", models.PostStatusDeleted).Error
	})
}

func (s *PollService) Get(pollID, viewerID uint) (models.Post, error) {
	var poll models.Poll
	if err := s.db.Select("id", "post_id").First(&poll, pollID).Error; err != nil {
		return models.Post{}, newPollError(PollCodeNotFound, "投票不存在")
	}
	return s.GetByPostID(poll.PostID, viewerID)
}

func (s *PollService) GetByPostID(postID, viewerID uint) (models.Post, error) {
	var post models.Post
	if err := s.db.Preload("Author").Preload("Images").Preload("Images.File").Preload("Images.Variants", "recipe_version = ?", ImageVariantRecipeVersion).First(&post, postID).Error; err != nil {
		return models.Post{}, newPollError(PollCodeNotFound, "投票不存在")
	}
	if post.ContentKind != models.PostContentKindPoll || !isPublicPollPostStatus(post.Status) {
		return models.Post{}, newPollError(PollCodeNotFound, "投票不存在")
	}
	posts := []models.Post{post}
	if err := s.HydratePollPosts(posts, viewerID); err != nil {
		return models.Post{}, err
	}
	if posts[0].PollMeta == nil || posts[0].PollMeta.EffectiveStatus == models.PollStatusDeleted {
		return models.Post{}, newPollError(PollCodeNotFound, "投票不存在")
	}
	return posts[0], nil
}

func (s *PollService) List(input PollListInput, viewerID uint) (PollListResult, error) {
	input = normalizePollListInput(input)
	var cursor pollListCursor
	hasCursor := strings.TrimSpace(input.Cursor) != ""
	cursorStale := false
	if hasCursor {
		decoded, ok := DecodePollListCursor(input.Cursor, input.Sort)
		if !ok {
			// 位置失效就老老实实回到第一页：拿着一个错位的游标往下翻，
			// 比让用户重新拉一次更容易造成「少一条/多一条」的错觉。
			cursorStale = true
			hasCursor = false
			// 真的回到第一页：只把 page 字段改成 1、查询仍按原 page 走 offset，
			// 会让客户端拿到一个空的「第一页」，看起来像列表被清空了。
			input.Page = 1
		} else {
			cursor = decoded
		}
	}
	query := s.db.Model(&models.Post{}).
		Joins("JOIN polls ON polls.post_id = posts.id").
		Where("posts.content_kind = ? AND posts.status IN ? AND polls.status <> ?", models.PostContentKindPoll, models.PublicPostStatuses(), models.PollStatusDeleted)
	if input.Category != "all" {
		query = query.Where("polls.category = ?", input.Category)
	}
	if input.Scope == "created" {
		query = query.Where("posts.author_id = ?", input.UserID)
	} else if input.Scope == "voted" {
		query = query.Joins("JOIN poll_ballots ON poll_ballots.poll_id = polls.id AND poll_ballots.user_id = ?", input.UserID)
	}
	if input.Sort == "ending" {
		query = query.Where("polls.status = ? AND polls.ends_at > ?", models.PollStatusActive, s.now())
	}
	var matched int64
	if err := query.Count(&matched).Error; err != nil {
		return PollListResult{}, err
	}
	result := PollListResult{Page: input.Page, Limit: input.Limit, MatchedTotal: matched, CursorStale: cursorStale}
	if cursorStale {
		result.Page = 1
	}

	var posts []models.Post
	if input.Sort == "recommend" {
		// 推荐顺序由内存评分决定，本身随时间变化，做不到真正的快照续页。
		// 这里退一步但把最要命的漂移堵死：用锚点钉住候选池上边界，新发布的投票
		// 不会挤进已经翻过的页（offset 分页在并发新增下漏条/重条的直接成因）。
		// 池内顺序对同一锚点是稳定的，池里被删掉的条目仍可能让下标偏移，
		// 那种情况由客户端回到第一页恢复，不在这里假装成快照一致。
		poolQuery := query
		anchorTime, anchorID := time.Time{}, uint(0)
		if hasCursor {
			anchorTime, anchorID = cursor.PoolAnchorTime, cursor.PoolAnchorID
			poolQuery = poolQuery.Where(
				pollKeysetAtOrBefore("posts.created_at", "posts.id"),
				anchorTime, anchorTime, anchorID)
		}
		if err := poolQuery.Order("posts.created_at DESC, posts.id DESC").Preload("Author").Preload("Images").Preload("Images.File").Preload("Images.Variants", "recipe_version = ?", ImageVariantRecipeVersion).Limit(pollRecommendPoolSize).Find(&posts).Error; err != nil {
			return PollListResult{}, err
		}
		result.PoolSize = pollRecommendPoolSize
		// total 表示本次可分页的候选数：池外的投票在这一路永远翻不到，
		// 计入总数会让 has_more 一直指向空白页；全站匹配数由 matched_total 承担。
		result.Total = int64(len(posts))
		if len(posts) == 0 {
			if hasCursor {
				// 锚点内的候选全部消失时，旧池已无法续页；回到当前第一页，
				// 让锚点之后新发布的投票也能重新进入列表。
				input.Cursor = ""
				input.Page = 1
				fresh, err := s.List(input, viewerID)
				if err != nil {
					return PollListResult{}, err
				}
				fresh.CursorStale = true
				return fresh, nil
			}
			posts = []models.Post{}
			result.Items = posts
			return result, nil
		}
		if !hasCursor {
			// 首页定锚点：取当前池里排序最靠前（最新）的一条。
			anchorTime, anchorID = posts[0].CreatedAt, posts[0].ID
		}
		if err := s.HydratePollPosts(posts, viewerID); err != nil {
			return PollListResult{}, err
		}
		now := s.now()
		sort.SliceStable(posts, func(i, j int) bool { return pollRecommendScore(posts[i], now) > pollRecommendScore(posts[j], now) })
		poolOrderHash := pollRecommendOrderFingerprint(posts)
		if hasCursor && cursor.PoolOrderHash != poolOrderHash {
			// 投票数、回复数、点赞数或候选成员变化会改变推荐顺序。旧下标此时
			// 不再指向同一位置，返回新第一页并要求客户端整体替换。
			input.Cursor = ""
			input.Page = 1
			result, err := s.List(input, viewerID)
			if err != nil {
				return PollListResult{}, err
			}
			result.CursorStale = true
			return result, nil
		}
		start := (input.Page - 1) * input.Limit
		if hasCursor {
			start = cursor.Index
		}
		if start > len(posts) {
			start = len(posts)
		}
		end := start + input.Limit
		if end > len(posts) {
			end = len(posts)
		}
		result.HasMore = end < len(posts)
		posts = posts[start:end]
		if result.HasMore {
			result.NextCursor = EncodePollListCursor(pollListCursor{
				Sort:           input.Sort,
				PoolAnchorTime: anchorTime,
				PoolAnchorID:   anchorID,
				PoolOrderHash:  poolOrderHash,
				Index:          end,
			})
		}
	} else {
		// created_at/ends_at 同值时用 posts.id 兜底：没有二级键的话数据库可以任意排，
		// 翻页就会跨页重复或漏掉同一秒发布的投票。二级键统一用 posts.id，
		// 这样 keyset 游标只需要记住 Post 的身份，不必再带上 polls.id。
		timeColumn, descending := "posts.created_at", true
		if input.Sort == "ending" {
			timeColumn, descending = "polls.ends_at", false
		}
		order := timeColumn + " DESC, posts.id DESC"
		if !descending {
			order = timeColumn + " ASC, posts.id ASC"
		}
		if hasCursor {
			// keyset 续页：条件跟着排序键走，与「已经翻过多少条」无关。
			// 并发新增因此既不会挤掉下一页，也不会让同一条被翻到两次。
			if descending {
				query = query.Where(pollKeysetBefore(timeColumn, "posts.id"),
					cursor.KeyTime, cursor.KeyTime, cursor.KeyID)
			} else {
				query = query.Where(pollKeysetAfter(timeColumn, "posts.id"),
					cursor.KeyTime, cursor.KeyTime, cursor.KeyID)
			}
		} else {
			// 没有游标时保留 offset 路径，兼容还在用 page 翻页的旧客户端。
			query = query.Offset((input.Page - 1) * input.Limit)
		}
		if err := query.Preload("Author").Preload("Images").Preload("Images.File").Preload("Images.Variants", "recipe_version = ?", ImageVariantRecipeVersion).Order(order).Limit(input.Limit + 1).Find(&posts).Error; err != nil {
			return PollListResult{}, err
		}
		// 多取一条判断还有没有下一页：比用 total 反推更准，
		// 并发写入让总数在翻页之间变化时，按 total 推出来的 has_more 会说谎。
		result.HasMore = len(posts) > input.Limit
		if result.HasMore {
			posts = posts[:input.Limit]
		}
		if err := s.HydratePollPosts(posts, viewerID); err != nil {
			return PollListResult{}, err
		}
		// 这一路没有候选池，全部匹配项都可分页，因此 total 与 matched_total 相同。
		result.Total = matched
		if result.HasMore && len(posts) > 0 {
			last := posts[len(posts)-1]
			keyTime := last.CreatedAt
			if input.Sort == "ending" && last.PollMeta != nil {
				keyTime = last.PollMeta.EndsAt
			}
			result.NextCursor = EncodePollListCursor(pollListCursor{
				Sort:    input.Sort,
				KeyTime: keyTime,
				KeyID:   last.ID,
			})
		}
	}
	if posts == nil {
		posts = []models.Post{}
	}
	result.Items = posts
	return result, nil
}

// pollRecommendOrderFingerprint 只摘要稳定排序后的 ID 序列；
// 个别分数变化但顺序没变时可以继续，顺序或候选成员一旦变化就回到第一页。
func pollRecommendOrderFingerprint(posts []models.Post) string {
	ids := make([]byte, 0, len(posts)*12)
	for _, post := range posts {
		ids = strconv.AppendUint(ids, uint64(post.ID), 10)
		ids = append(ids, '|')
	}
	sum := sha256.Sum256(ids)
	return hex.EncodeToString(sum[:])
}

// HydratePollPosts 用固定批次数查询为帖子填充投票摘要，避免首页 N+1。
func (s *PollService) HydratePollPosts(posts []models.Post, viewerID uint) error {
	postIDs := make([]uint, 0, len(posts))
	for i := range posts {
		if posts[i].ContentKind == models.PostContentKindPoll {
			postIDs = append(postIDs, posts[i].ID)
			posts[i].WaterSectionAuthorMeta = nil
		}
	}
	_ = LoadTopicsForPosts(s.db, posts)
	if len(postIDs) == 0 {
		return nil
	}
	var polls []models.Poll
	if err := s.db.Where("post_id IN ?", postIDs).Preload("Options", func(db *gorm.DB) *gorm.DB { return db.Order("sort_order ASC") }).Find(&polls).Error; err != nil {
		return err
	}
	chosenByPoll := map[uint]map[uint]bool{}
	hasVoted := map[uint]bool{}
	if viewerID != 0 && len(polls) > 0 {
		pollIDs := make([]uint, 0, len(polls))
		for _, poll := range polls {
			pollIDs = append(pollIDs, poll.ID)
		}
		var ballots []models.PollBallot
		if err := s.db.Where("poll_id IN ? AND user_id = ?", pollIDs, viewerID).Preload("Choices").Find(&ballots).Error; err != nil {
			return err
		}
		for _, ballot := range ballots {
			hasVoted[ballot.PollID] = true
			chosenByPoll[ballot.PollID] = map[uint]bool{}
			for _, choice := range ballot.Choices {
				chosenByPoll[ballot.PollID][choice.OptionID] = true
			}
		}
	}
	pollByPost := make(map[uint]models.Poll, len(polls))
	for _, poll := range polls {
		pollByPost[poll.PostID] = poll
	}
	now := s.now()
	for i := range posts {
		poll, ok := pollByPost[posts[i].ID]
		if !ok {
			continue
		}
		posts[i].PollMeta = buildPollSummary(poll, posts[i], viewerID, hasVoted[poll.ID], chosenByPoll[poll.ID], now)
	}
	return nil
}

func RecalculatePollCounts(db *gorm.DB, pollID uint) error {
	return db.Transaction(func(tx *gorm.DB) error {
		var participantCount int64
		if err := tx.Model(&models.PollBallot{}).Where("poll_id = ?", pollID).Count(&participantCount).Error; err != nil {
			return err
		}
		var choiceCount int64
		if err := tx.Table("poll_ballot_choices pbc").Joins("JOIN poll_ballots pb ON pb.id = pbc.ballot_id").Where("pb.poll_id = ?", pollID).Count(&choiceCount).Error; err != nil {
			return err
		}
		if err := tx.Model(&models.PollOption{}).Where("poll_id = ?", pollID).Update("vote_count", 0).Error; err != nil {
			return err
		}
		var counts []struct {
			OptionID uint
			Count    int
		}
		if err := tx.Table("poll_ballot_choices pbc").Select("pbc.option_id, COUNT(*) AS count").Joins("JOIN poll_ballots pb ON pb.id = pbc.ballot_id").Where("pb.poll_id = ?", pollID).Group("pbc.option_id").Scan(&counts).Error; err != nil {
			return err
		}
		for _, count := range counts {
			if err := tx.Model(&models.PollOption{}).Where("id = ? AND poll_id = ?", count.OptionID, pollID).Update("vote_count", count.Count).Error; err != nil {
				return err
			}
		}
		return tx.Model(&models.Poll{}).Where("id = ?", pollID).Updates(map[string]interface{}{"participant_count": participantCount, "choice_count": choiceCount}).Error
	})
}

func (s *PollService) validateInput(input CreatePollInput, now time.Time) (CreatePollInput, error) {
	input.Title = strings.TrimSpace(input.Title)
	input.Description = strings.TrimSpace(input.Description)
	input.Category = strings.TrimSpace(input.Category)
	input.SelectionMode = strings.TrimSpace(input.SelectionMode)
	input.ResultsVisibility = strings.TrimSpace(input.ResultsVisibility)
	if countRunes(input.Title) < 1 || countRunes(input.Title) > 80 {
		return input, newPollError(PollCodeInvalidInput, "标题长度需为 1 至 80 字")
	}
	if err := validatePollMutableInput(&input); err != nil {
		return input, err
	}
	if len(input.Options) < 2 || len(input.Options) > 10 {
		return input, newPollError(PollCodeInvalidInput, "投票选项需为 2 至 10 项")
	}
	seen := map[string]bool{}
	for i := range input.Options {
		input.Options[i] = strings.TrimSpace(input.Options[i])
		if countRunes(input.Options[i]) < 1 || countRunes(input.Options[i]) > 50 {
			return input, newPollError(PollCodeInvalidOption, "单个选项长度需为 1 至 50 字")
		}
		key := strings.ToLower(input.Options[i])
		if seen[key] {
			return input, newPollError(PollCodeInvalidOption, "投票选项不能重复")
		}
		seen[key] = true
	}
	if input.EndsAt.Before(now.Add(30*time.Minute)) || input.EndsAt.After(now.Add(30*24*time.Hour)) {
		return input, newPollError(PollCodeInvalidInput, "截止时间需在 30 分钟至 30 天内")
	}
	validCategories := map[string]bool{models.PollCategoryCampusLife: true, models.PollCategoryStudy: true, models.PollCategoryActivity: true, models.PollCategoryOther: true}
	if !validCategories[input.Category] {
		return input, newPollError(PollCodeInvalidInput, "投票分类无效")
	}
	validVisibility := map[string]bool{
		models.PollResultsAlways:    true,
		models.PollResultsAfterVote: true, // 兼容历史投票，新客户端不再提供此选项。
		models.PollResultsAfterEnd:  true,
		models.PollResultsPrivate:   true,
	}
	if !validVisibility[input.ResultsVisibility] {
		return input, newPollError(PollCodeInvalidInput, "结果可见方式无效")
	}
	if input.SelectionMode == models.PollSelectionSingle {
		if input.MaxChoices != 1 {
			return input, newPollError(PollCodeInvalidChoiceCount, "单选投票最多只能选择 1 项")
		}
	} else if input.SelectionMode == models.PollSelectionMultiple {
		if input.MaxChoices < 2 || input.MaxChoices > len(input.Options) {
			return input, newPollError(PollCodeInvalidChoiceCount, "多选数量超出有效范围")
		}
	} else {
		return input, newPollError(PollCodeInvalidInput, "投票选择模式无效")
	}
	return input, nil
}

func validatePollMutableInput(input *CreatePollInput) error {
	input.Description = strings.TrimSpace(input.Description)
	if countRunes(input.Description) > 1000 {
		return newPollError(PollCodeInvalidInput, "补充说明不能超过 1000 字")
	}
	if len(input.FileIDs) > 3 {
		return newPollError(PollCodeInvalidInput, "图片不能超过 3 张")
	}
	return nil
}

func (s *PollService) checkCreationLimit(db *gorm.DB, userID uint, now time.Time) error {
	var active int64
	if err := db.Model(&models.Poll{}).Joins("JOIN posts ON posts.id = polls.post_id").Where("posts.author_id = ? AND posts.status = ? AND polls.status = ? AND polls.ends_at > ?", userID, models.PostStatusNormal, models.PollStatusActive, now).Count(&active).Error; err != nil {
		return err
	}
	if active >= 5 {
		return newPollError(PollCodeCreationLimit, "最多同时发起 5 个进行中的投票")
	}
	var recent int64
	if err := db.Model(&models.Poll{}).Joins("JOIN posts ON posts.id = polls.post_id").Where("posts.author_id = ? AND polls.created_at >= ?", userID, now.Add(-24*time.Hour)).Count(&recent).Error; err != nil {
		return err
	}
	if recent >= 5 {
		return newPollError(PollCodeCreationLimit, "24 小时内最多发起 5 个投票")
	}
	return nil
}

func buildPollSummary(poll models.Poll, post models.Post, viewerID uint, hasVoted bool, chosen map[uint]bool, now time.Time) *models.PollSummaryDTO {
	status := effectivePollStatus(poll, post.Status, now)
	resultsVisible := poll.ResultsVisibility == models.PollResultsAlways ||
		(poll.ResultsVisibility == models.PollResultsAfterVote && hasVoted) ||
		(poll.ResultsVisibility == models.PollResultsAfterEnd && status == models.PollStatusClosed) ||
		(poll.ResultsVisibility == models.PollResultsPrivate && viewerID != 0 && viewerID == post.AuthorID)
	remaining := int64(poll.EndsAt.Sub(now).Seconds())
	if remaining < 0 {
		remaining = 0
	}
	dto := &models.PollSummaryDTO{
		ID: poll.ID, PostID: poll.PostID, Category: poll.Category, SelectionMode: poll.SelectionMode,
		MaxChoices: poll.MaxChoices, ResultsVisibility: poll.ResultsVisibility, AllowChange: poll.AllowChange,
		Status: poll.Status, EffectiveStatus: status, EndsAt: poll.EndsAt, RemainingSeconds: remaining,
		ParticipantCount: poll.ParticipantCount, HasVoted: hasVoted, ResultsVisible: resultsVisible,
		CanViewResult: resultsVisible,
		CanVote:       viewerID != 0 && status == models.PollStatusActive && (!hasVoted || poll.AllowChange),
		CanChange:     viewerID != 0 && hasVoted && poll.AllowChange && status == models.PollStatusActive,
		IsOwner:       viewerID != 0 && viewerID == post.AuthorID,
		Options:       make([]models.PollOptionDTO, 0, len(poll.Options)),
	}
	if resultsVisible {
		choiceCount := poll.ChoiceCount
		dto.ChoiceCount = &choiceCount
	}
	for _, option := range poll.Options {
		optionDTO := models.PollOptionDTO{ID: option.ID, Text: option.Text, SortOrder: option.SortOrder, IsChosen: chosen[option.ID]}
		if resultsVisible {
			votes := option.VoteCount
			ratio := 0.0
			if poll.ParticipantCount > 0 {
				ratio = float64(votes) / float64(poll.ParticipantCount)
			}
			optionDTO.VoteCount = &votes
			optionDTO.Ratio = &ratio
		}
		dto.Options = append(dto.Options, optionDTO)
	}
	return dto
}

func effectivePollStatus(poll models.Poll, postStatus models.PostStatus, now time.Time) string {
	if poll.Status == models.PollStatusDeleted || !isPublicPollPostStatus(postStatus) {
		return models.PollStatusDeleted
	}
	if poll.Status == models.PollStatusClosed || !now.Before(poll.EndsAt) {
		return models.PollStatusClosed
	}
	return models.PollStatusActive
}

// 投票只能公开挂在当前可公开读取的帖子上；未知状态默认拒绝，避免治理状态新增后被反向放行。
func isPublicPollPostStatus(status models.PostStatus) bool {
	return models.IsPublicPostStatus(status)
}

func validateChoiceIDs(poll models.Poll, options []models.PollOption, optionIDs []uint) ([]uint, error) {
	valid := make(map[uint]bool, len(options))
	for _, option := range options {
		valid[option.ID] = true
	}
	seen := make(map[uint]bool, len(optionIDs))
	unique := make([]uint, 0, len(optionIDs))
	for _, id := range optionIDs {
		if id == 0 || !valid[id] || seen[id] {
			return nil, newPollError(PollCodeInvalidOption, "投票选项无效或重复")
		}
		seen[id] = true
		unique = append(unique, id)
	}
	if poll.SelectionMode == models.PollSelectionSingle {
		if len(unique) != 1 {
			return nil, newPollError(PollCodeInvalidChoiceCount, "单选投票必须选择 1 项")
		}
	} else if len(unique) < 1 || len(unique) > poll.MaxChoices {
		return nil, newPollError(PollCodeInvalidChoiceCount, fmt.Sprintf("请选择 1 至 %d 项", poll.MaxChoices))
	}
	return unique, nil
}

func lockedRulesChanged(post models.Post, poll models.Poll, options []models.PollOption, input CreatePollInput) bool {
	if strings.TrimSpace(input.Title) != post.Title || input.Category != poll.Category || input.SelectionMode != poll.SelectionMode ||
		input.MaxChoices != poll.MaxChoices || input.ResultsVisibility != poll.ResultsVisibility || input.AllowChange != poll.AllowChange ||
		!input.EndsAt.Equal(poll.EndsAt) || len(input.Options) != len(options) {
		return true
	}
	for i := range options {
		if strings.TrimSpace(input.Options[i]) != options[i].Text {
			return true
		}
	}
	return false
}

func replacePostImages(tx *gorm.DB, postID uint, fileIDs []uint) error {
	if err := tx.Where("post_id = ?", postID).Delete(&models.PostImage{}).Error; err != nil {
		return err
	}
	for i, fileID := range fileIDs {
		if err := tx.Create(&models.PostImage{PostID: postID, FileID: fileID, SortOrder: i}).Error; err != nil {
			return err
		}
	}
	return nil
}

func (s *PollService) acquirePollWriteLock() func() {
	if s.db.Dialector.Name() != "sqlite" {
		return func() {}
	}
	pollWriteLock.Lock()
	return pollWriteLock.Unlock
}

func isAdminRole(role string) bool {
	return role == string(models.RoleAdmin) || role == string(models.RoleSuperAdmin)
}
func countRunes(value string) int { return len([]rune(value)) }

func sameUintSet(a, b []uint) bool {
	if len(a) != len(b) {
		return false
	}
	set := make(map[uint]bool, len(a))
	for _, id := range a {
		set[id] = true
	}
	for _, id := range b {
		if !set[id] {
			return false
		}
	}
	return true
}

func normalizePollListInput(input PollListInput) PollListInput {
	if input.Page < 1 {
		input.Page = 1
	}
	if input.Limit < 1 {
		input.Limit = 20
	}
	if input.Limit > 50 {
		input.Limit = 50
	}
	if input.Sort != "latest" && input.Sort != "ending" {
		input.Sort = "recommend"
	}
	validCategory := input.Category == "all" || input.Category == models.PollCategoryCampusLife || input.Category == models.PollCategoryStudy || input.Category == models.PollCategoryActivity || input.Category == models.PollCategoryOther
	if !validCategory {
		input.Category = "all"
	}
	return input
}

func pollRecommendScore(post models.Post, now time.Time) float64 {
	ageHours := math.Max(now.Sub(post.CreatedAt).Hours(), 0)
	score := 8 / (1 + ageHours/18)
	if post.PollMeta != nil {
		score += math.Min(math.Log1p(float64(post.PollMeta.ParticipantCount))*1.5, 6)
		if post.PollMeta.EffectiveStatus != models.PollStatusActive {
			score *= 0.45
		}
	}
	score += math.Min(float64(post.ReplyCount)*0.35, 4)
	score += math.Min(float64(post.LikeCount)*0.2, 3)
	return score
}
