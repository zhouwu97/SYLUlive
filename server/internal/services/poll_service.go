package services

import (
	"errors"
	"fmt"
	"math"
	"sort"
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
}

type PollListResult struct {
	Items []models.Post `json:"items"`
	Page  int           `json:"page"`
	Limit int           `json:"limit"`
	Total int64         `json:"total"`
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

func (s *PollService) Create(userID uint, role string, input CreatePollInput) (models.Post, error) {
	if userID == 0 {
		return models.Post{}, newPollError(PollCodePermissionDenied, "请先登录")
	}
	input, err := s.validateInput(input, s.now())
	if err != nil {
		return models.Post{}, err
	}
	unlock := s.acquirePollWriteLock()
	defer unlock()

	now := s.now()
	post := models.Post{
		Title:          input.Title,
		Content:        input.Description,
		BoardID:        models.BoardShuitie,
		AuthorID:       userID,
		PostType:       "poll",
		ContentKind:    models.PostContentKindPoll,
		Status:         models.PostStatusNormal,
		CreatedAt:      now,
		LastActivityAt: now,
	}
	err = s.db.Transaction(func(tx *gorm.DB) error {
		// PostgreSQL 使用用户行锁把“额度检查 + 创建”串成一个事务；
		// SQLite 由 acquirePollWriteLock 提供同等的测试环境串行语义。
		var user models.User
		if err := tx.Clauses(clause.Locking{Strength: "UPDATE"}).Select("id").First(&user, userID).Error; err != nil {
			return newPollError(PollCodePermissionDenied, "用户不存在")
		}
		if !isAdminRole(role) {
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
		if err := tx.First(&post, poll.PostID).Error; err != nil {
			return newPollError(PollCodeNotFound, "投票不存在")
		}
		if poll.Status == models.PollStatusDeleted || post.Status == models.PostStatusDeleted {
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
		if err := tx.Select("id", "status").First(&post, poll.PostID).Error; err != nil {
			return newPollError(PollCodeNotFound, "投票不存在")
		}
		postID = post.ID
		status := effectivePollStatus(poll, post.Status, s.now())
		if status == models.PollStatusDeleted {
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
		if err := tx.First(&post, poll.PostID).Error; err != nil {
			return newPollError(PollCodeNotFound, "投票不存在")
		}
		postID = post.ID
		if poll.Status == models.PollStatusDeleted || post.Status == models.PostStatusDeleted {
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
		if err := tx.First(&post, poll.PostID).Error; err != nil {
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
	if err := s.db.Preload("Author").Preload("Images").Preload("Images.File").First(&post, postID).Error; err != nil {
		return models.Post{}, newPollError(PollCodeNotFound, "投票不存在")
	}
	if post.ContentKind != models.PostContentKindPoll || post.Status == models.PostStatusDeleted {
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
	query := s.db.Model(&models.Post{}).
		Joins("JOIN polls ON polls.post_id = posts.id").
		Where("posts.content_kind = ? AND posts.status = ? AND polls.status <> ?", models.PostContentKindPoll, models.PostStatusNormal, models.PollStatusDeleted)
	if input.Category != "all" {
		query = query.Where("polls.category = ?", input.Category)
	}
	if input.Scope == "created" {
		query = query.Where("posts.author_id = ?", input.UserID)
	} else if input.Scope == "voted" {
		query = query.Joins("JOIN poll_ballots ON poll_ballots.poll_id = polls.id AND poll_ballots.user_id = ?", input.UserID)
	}
	var total int64
	if err := query.Count(&total).Error; err != nil {
		return PollListResult{}, err
	}

	var posts []models.Post
	if input.Sort == "recommend" {
		if err := query.Preload("Author").Preload("Images").Preload("Images.File").Limit(500).Find(&posts).Error; err != nil {
			return PollListResult{}, err
		}
		if err := s.HydratePollPosts(posts, viewerID); err != nil {
			return PollListResult{}, err
		}
		now := s.now()
		sort.SliceStable(posts, func(i, j int) bool { return pollRecommendScore(posts[i], now) > pollRecommendScore(posts[j], now) })
		posts = pagePosts(posts, input.Page, input.Limit)
	} else {
		if input.Sort == "ending" {
			query = query.Where("polls.status = ? AND polls.ends_at > ?", models.PollStatusActive, s.now()).Order("polls.ends_at ASC")
		} else {
			query = query.Order("posts.created_at DESC")
		}
		if err := query.Preload("Author").Preload("Images").Preload("Images.File").Offset((input.Page - 1) * input.Limit).Limit(input.Limit).Find(&posts).Error; err != nil {
			return PollListResult{}, err
		}
		if err := s.HydratePollPosts(posts, viewerID); err != nil {
			return PollListResult{}, err
		}
	}
	if posts == nil {
		posts = []models.Post{}
	}
	return PollListResult{Items: posts, Page: input.Page, Limit: input.Limit, Total: total}, nil
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
	if poll.Status == models.PollStatusDeleted || postStatus == models.PostStatusDeleted {
		return models.PollStatusDeleted
	}
	if poll.Status == models.PollStatusClosed || !now.Before(poll.EndsAt) {
		return models.PollStatusClosed
	}
	return models.PollStatusActive
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

func pagePosts(posts []models.Post, page, limit int) []models.Post {
	start := (page - 1) * limit
	if start >= len(posts) {
		return []models.Post{}
	}
	end := start + limit
	if end > len(posts) {
		end = len(posts)
	}
	return posts[start:end]
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
