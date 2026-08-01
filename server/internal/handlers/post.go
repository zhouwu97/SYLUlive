package handlers

import (
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"net/http"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"time"
	"unicode/utf8"

	"shenliyuan/internal/models"
	"shenliyuan/internal/services"

	"github.com/gin-gonic/gin"
	"gorm.io/gorm"
	"gorm.io/gorm/clause"
)

// PostHandler 帖子处理器
type PostHandler struct {
	db                *gorm.DB
	jpushAppKey       string
	jpushMasterSecret string
}

// NewPostHandler 创建帖子处理器
func NewPostHandler(db *gorm.DB, jpushAppKey, jpushMasterSecret string) *PostHandler {
	return &PostHandler{db: db, jpushAppKey: jpushAppKey, jpushMasterSecret: jpushMasterSecret}
}

// Snapshot 帖子快照
type Snapshot struct {
	PostIDs          []uint
	ExpiredAt        time.Time
	AlgorithmVersion string
	Sort             string
	FeedKind         string
}

var ActiveSnapshots sync.Map // key: session_id (string), value: Snapshot

var allowedWaterPostTypes = map[string]struct{}{
	"freshman_help": {},
	"course_study":  {},
	"competition":   {},
	"campus_life":   {},
	"complaint":     {},
	"experience":    {},
	"campus_news":   {},
}

var allowedMarketTags = map[string]struct{}{
	"自提":     {},
	"可送宿舍楼下": {},
	"可小刀":    {},
	"急出":     {},
}

var (
	marketWeChatPattern = regexp.MustCompile(`^[A-Za-z0-9_.-]+$`)
	marketQQPattern     = regexp.MustCompile(`^[0-9]+$`)
	marketPhonePattern  = regexp.MustCompile(`^[0-9 +\-]+$`)
)

func normalizeMarketContact(
	boardID models.BoardID,
	contactType string,
	contact string,
) (models.MarketContactType, string, error) {
	if boardID != models.BoardMarket {
		return "", "", nil
	}

	contactType = strings.TrimSpace(strings.ToLower(contactType))
	contact = strings.TrimSpace(contact)
	if contactType == "" && contact == "" {
		return "", "", nil
	}
	if contactType == "" {
		// 旧客户端只提交 contact；缺失类型时沿用历史数据解析规则。
		legacyType, legacyContact := models.ParseLegacyMarketContact(contact)
		return legacyType, legacyContact, nil
	}

	var normalizedType models.MarketContactType
	var emptyMessage string
	var pattern *regexp.Regexp
	switch models.MarketContactType(contactType) {
	case models.MarketContactTypeWeChat:
		normalizedType = models.MarketContactTypeWeChat
		emptyMessage = "请输入微信号"
		pattern = marketWeChatPattern
	case models.MarketContactTypeQQ:
		normalizedType = models.MarketContactTypeQQ
		emptyMessage = "请输入QQ号"
		pattern = marketQQPattern
	case models.MarketContactTypePhone:
		normalizedType = models.MarketContactTypePhone
		emptyMessage = "请输入电话号码"
		pattern = marketPhonePattern
	default:
		return "", "", fmt.Errorf("不支持的联系方式类型")
	}

	if contact == "" {
		return "", "", fmt.Errorf("%s", emptyMessage)
	}
	if utf8.RuneCountInString(contact) > 100 {
		return "", "", fmt.Errorf("联系方式不能超过100个字符")
	}
	if !pattern.MatchString(contact) {
		return "", "", fmt.Errorf("%s格式不正确", marketContactTypeName(normalizedType))
	}
	return normalizedType, contact, nil
}

func marketContactTypeName(contactType models.MarketContactType) string {
	switch contactType {
	case models.MarketContactTypeWeChat:
		return "微信号"
	case models.MarketContactTypeQQ:
		return "QQ号"
	default:
		return "电话号码"
	}
}

func normalizeWaterPostType(boardID models.BoardID, postType string) (string, error) {
	postType = strings.TrimSpace(postType)
	if boardID != models.BoardShuitie {
		return postType, nil
	}
	if postType == "" {
		return "campus_life", nil
	}
	if _, ok := allowedWaterPostTypes[postType]; ok {
		return postType, nil
	}
	return "", fmt.Errorf("invalid water post_type: %s", postType)
}

func normalizeMarketTags(raw string) string {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return ""
	}
	seen := map[string]struct{}{}
	tags := []string{}
	for _, item := range strings.Split(raw, ",") {
		tag := strings.TrimSpace(item)
		if tag == "" {
			continue
		}
		if _, ok := allowedMarketTags[tag]; !ok {
			continue
		}
		if _, exists := seen[tag]; exists {
			continue
		}
		seen[tag] = struct{}{}
		tags = append(tags, tag)
	}
	return strings.Join(tags, ",")
}

// validateWaterSectionActive 校验 post_type 对应的版块存在且 active；返回版块 ID。
func validateWaterSectionActive(db *gorm.DB, postType string) (uint, error) {
	var section models.WaterSection
	err := db.Where("slug = ? AND status = ?", postType, "active").First(&section).Error
	if err == gorm.ErrRecordNotFound {
		return 0, fmt.Errorf("无效版块")
	}
	if err != nil {
		return 0, err
	}
	return section.ID, nil
}

// validateWaterTagBelongsToSection 校验标签属于该版块且启用；返回标签 ID（uint）以备写入。
func validateWaterTagBelongsToSection(db *gorm.DB, tagID uint, sectionID uint) error {
	var tag models.WaterSectionTag
	err := db.Where("id = ? AND section_id = ? AND is_enabled = ?", tagID, sectionID, true).First(&tag).Error
	if err == gorm.ErrRecordNotFound {
		return fmt.Errorf("标签不属于该版块")
	}
	return err
}

func applyPostTypeFilter(query *gorm.DB, requestedBoardID *models.BoardID, postType string) *gorm.DB {
	if postType == "" {
		return query
	}
	if requestedBoardID != nil &&
		*requestedBoardID == models.BoardShuitie &&
		postType == "campus_life" {
		return query.Where(
			"(post_type = ? OR post_type IS NULL OR post_type = '')",
			postType,
		)
	}
	return query.Where("post_type = ?", postType)
}

func supportsPollRequest(c *gin.Context) bool {
	feedVersion, _ := strconv.Atoi(c.Query("feed_version"))
	if feedVersion >= 3 {
		return true
	}
	for _, capability := range strings.Split(c.Query("capabilities"), ",") {
		if strings.TrimSpace(capability) == "poll_v1" {
			return true
		}
	}
	return false
}

// GetList 获取帖子列表
func (h *PostHandler) GetList(c *gin.Context) {
	boardIDStr := c.Query("board")
	postType := c.Query("type")
	searchQuery := strings.TrimSpace(strings.ToLower(c.Query("q")))
	sort := c.DefaultQuery("sort", "time")
	sinceStr := c.Query("since")
	feedVersion, _ := strconv.Atoi(c.Query("feed_version"))
	supportsPoll := supportsPollRequest(c)
	genericFeedKind := "generic"
	if supportsPoll {
		genericFeedKind = "generic_poll_v1"
	}

	scene := c.Query("scene") // refresh 或 loadmore
	sessionID := c.Query("session_id")
	offsetStr := c.Query("offset")

	page, limit, paginationOffset := ParsePagination(c, 20, 50)
	offset, _ := strconv.Atoi(offsetStr)

	// 如果是常规分页（没有传入scene或者只是普通请求），默认使用 offset
	if scene == "" && offset == 0 {
		offset = paginationOffset
	}

	var posts []models.Post
	var total int64
	now := time.Now()
	var requestedBoardID *models.BoardID
	var waterSectionFeedID uint

	isHomeFeedV2 := boardIDStr == "1" &&
		strings.TrimSpace(postType) == "" &&
		c.Query("tag_id") == "" &&
		feedVersion >= 2 &&
		(sort == "all" || sort == "time") &&
		searchQuery == "" &&
		sinceStr == ""

	if isHomeFeedV2 {
		h.getHomeFeedV2(c, sort, scene, sessionID, page, limit, offset, now, feedVersion >= 3)
		return
	}

	isLegacyHomeFeed := boardIDStr == "1" &&
		strings.TrimSpace(postType) == "" &&
		c.Query("tag_id") == "" &&
		feedVersion < 2 &&
		sort == "all" &&
		searchQuery == "" &&
		sinceStr == ""

	if isLegacyHomeFeed {
		h.getLegacyHomeFeedCompat(c, scene, sessionID, page, limit, offset, now)
		return
	}

	// 如果是加载更多，并且带有有效的 session_id，尝试走快照
	if scene == "loadmore" && sessionID != "" {
		if val, ok := ActiveSnapshots.Load(sessionID); ok {
			snapshot := val.(Snapshot)
			if time.Now().Before(snapshot.ExpiredAt) && snapshot.FeedKind == genericFeedKind {
				// 计算切片边界
				end := offset + limit
				if offset < len(snapshot.PostIDs) {
					if end > len(snapshot.PostIDs) {
						end = len(snapshot.PostIDs)
					}
					targetIDs := snapshot.PostIDs[offset:end]

					if len(targetIDs) > 0 {
						var rawPosts []models.Post
						if err := h.db.Model(&models.Post{}).Where("id IN ?", targetIDs).Preload("Author").Preload("Images").Preload("Images.File").Find(&rawPosts).Error; err != nil {
							log.Printf("[DB_ERROR] GetList hot-feed Find failed: %v", err)
							c.JSON(http.StatusInternalServerError, gin.H{"error": "获取帖子列表失败"})
							return
						}

						// 重组排序
						postMap := make(map[uint]models.Post)
						for _, p := range rawPosts {
							postMap[p.ID] = p
						}
						for _, id := range targetIDs {
							if p, exists := postMap[id]; exists {
								posts = append(posts, p)
							}
						}
					}

					// 直接返回，不再走正常查询
					h.hydratePosts(c, posts, time.Now())
					if posts == nil {
						posts = []models.Post{}
					}
					c.JSON(http.StatusOK, gin.H{
						"posts":      posts,
						"total":      len(snapshot.PostIDs),
						"page":       page,
						"limit":      limit,
						"session_id": sessionID,
					})
					return
				}
			} else {
				ActiveSnapshots.Delete(sessionID)
			}
		}
	}

	// 走正常的查询（或 refresh 阶段）
	query := h.db.Model(&models.Post{}).
		Where("posts.status != ?", models.PostStatusDeleted).
		Where("NOT EXISTS (SELECT 1 FROM water_team_recruitments wtr WHERE wtr.post_id = posts.id)").
		Preload("Author").Preload("Images").Preload("Images.File")
	if !supportsPoll {
		query = query.Where("posts.content_kind <> ?", models.PostContentKindPoll)
	}

	if boardIDStr != "" {
		boardID, err := strconv.Atoi(boardIDStr)
		if err == nil {
			bid := models.BoardID(boardID)
			requestedBoardID = &bid
			query = query.Where("board_id = ?", boardID)
		}
	}

	query = applyPostTypeFilter(query, requestedBoardID, postType)
	if requestedBoardID != nil && *requestedBoardID == models.BoardShuitie && postType != "" {
		if sectionID, err := validateWaterSectionActive(h.db, postType); err == nil {
			waterSectionFeedID = sectionID
		}
	}

	// tag_id 过滤：仅水帖版块生效
	tagIDStr := c.Query("tag_id")
	tagIDProvided := tagIDStr != ""
	var tagID uint
	if tagIDProvided {
		parsed, err := strconv.ParseUint(tagIDStr, 10, 64)
		if err != nil {
			c.JSON(http.StatusBadRequest, gin.H{"error": "无效的标签ID"})
			return
		}
		tagID = uint(parsed)
		// tag_id 仅支持水帖版块
		parsedBoard, boardErr := strconv.Atoi(boardIDStr)
		if boardErr != nil || models.BoardID(parsedBoard) != models.BoardShuitie {
			c.JSON(http.StatusBadRequest, gin.H{"error": "tag_id 仅支持水帖版块"})
			return
		}
		// 校验标签存在且属于 type 对应 section
		if postType != "" {
			sectionID, secErr := validateWaterSectionActive(h.db, postType)
			if secErr != nil {
				c.JSON(http.StatusBadRequest, gin.H{"error": "标签不属于该版块"})
				return
			}
			if tagErr := validateWaterTagBelongsToSection(h.db, tagID, sectionID); tagErr != nil {
				c.JSON(http.StatusBadRequest, gin.H{"error": tagErr.Error()})
				return
			}
		} else {
			// 未指定 type：只要标签存在且属于任意 active section
			var exists int64
			h.db.Model(&models.WaterSectionTag{}).
				Joins("JOIN water_sections ON water_sections.id = water_section_tags.section_id").
				Where("water_section_tags.id = ? AND water_section_tags.is_enabled = ? AND water_sections.status = ?",
					tagID, true, "active").
				Count(&exists)
			if exists == 0 {
				c.JSON(http.StatusBadRequest, gin.H{"error": "标签不属于该版块"})
				return
			}
		}
		query = query.Where("water_tag_id = ?", tagID)
	}

	// 版块“推荐”使用独立快照算法；带标签、搜索或增量条件的请求继续走通用查询。
	isSectionRecommend := requestedBoardID != nil &&
		*requestedBoardID == models.BoardShuitie &&
		postType != "" &&
		waterSectionFeedID > 0 &&
		!tagIDProvided &&
		sort == "all" &&
		searchQuery == "" &&
		sinceStr == ""

	if sinceStr != "" {
		sinceTime, err := time.Parse(time.RFC3339, sinceStr)
		if err == nil {
			query = query.Where("updated_at > ?", sinceTime)
		}
	}

	// 关注信息：仅展示当前用户关注的版块内的帖子（水帖）
	if sort == "following" {
		rawUserID, exists := c.Get("user_id")
		userID, ok := rawUserID.(uint)
		if !exists || !ok || userID == 0 {
			c.JSON(http.StatusUnauthorized, gin.H{
				"error": "请先登录查看关注动态",
			})
			return
		}
		followingSubQuery := h.db.
			Model(&models.WaterSectionFollow{}).
			Joins("JOIN water_sections ON water_sections.id = water_section_follows.section_id").
			Select("water_sections.slug").
			Where("water_section_follows.user_id = ?", userID)
		query = query.Where("posts.board_id = ? AND posts.post_type IN (?)", models.BoardShuitie, followingSubQuery)
	}

	if searchQuery != "" {
		searchLike := "%" + searchQuery + "%"
		query = query.Where(
			"(LOWER(title) LIKE ? OR LOWER(content) LIKE ?)",
			searchLike,
			searchLike,
		)
		query = query.Clauses(clause.OrderBy{
			Expression: clause.Expr{
				SQL: `CASE
				WHEN LOWER(title) = ? THEN 0
				WHEN LOWER(title) LIKE ? THEN 1
				WHEN LOWER(title) LIKE ? THEN 2
				WHEN LOWER(content) LIKE ? THEN 3
				ELSE 4
			END ASC,
			CASE
				WHEN is_pinned = ? AND (pinned_until IS NULL OR pinned_until > ?)
				THEN 0 ELSE 1
			END ASC,
			CASE WHEN is_pinned = ? AND (pinned_until IS NULL OR pinned_until > ?) THEN posts.pinned_weight ELSE 0 END DESC,
			CASE WHEN is_pinned = ? AND (pinned_until IS NULL OR pinned_until > ?) THEN posts.pinned_at ELSE NULL END DESC NULLS LAST,
			posts.created_at DESC`,
				Vars: []interface{}{
					searchQuery,
					searchQuery + "%",
					searchLike,
					searchLike,
					true,
					now,
					true,
					now,
					true,
					now,
				},
				WithoutParentheses: true,
			},
		})
	}

	// 动态算法拦截
	isSnapshotting := false
	if scene != "loadmore" && (sort == "all" || sort == "hot") && searchQuery == "" && sinceStr == "" {
		isSnapshotting = true
		if sort == "all" {
			query = applyWaterSectionPinOrder(query, waterSectionFeedID, now)
			query = applyPinnedOrder(query, now)

			var isTeamTag bool
			if tagIDProvided {
				var tag models.WaterSectionTag
				if h.db.First(&tag, tagID).Error == nil && tag.ContentMode == models.WaterTagModeTeamRecruitment {
					isTeamTag = true
				}
			}
			if isTeamTag {
				query = query.Joins("LEFT JOIN water_team_recruitments wtr ON wtr.post_id = posts.id")
				query = query.Order(clause.Expr{SQL: `CASE WHEN wtr.status = ? AND (wtr.deadline IS NULL OR wtr.deadline > ?) THEN 0 WHEN wtr.status = ? THEN 1 ELSE 2 END ASC`, Vars: []interface{}{models.RecruitmentStatusRecruiting, now, models.RecruitmentStatusFull}})
			}

			query = query.Order(clause.Expr{SQL: "(10.0 + posts.like_count*5 + posts.reply_count*10 + posts.view_count*0.2) / POWER((EXTRACT(EPOCH FROM (? - posts.created_at))/3600.0 + 2), 2) DESC", Vars: []interface{}{now}})
		} else if sort == "hot" {
			query = applyWaterSectionPinOrder(query, waterSectionFeedID, now)
			query = query.Order("(posts.view_count*1 + posts.like_count*20 + posts.reply_count*50) DESC")
		}
	} else {
		// 常规排序
		switch sort {
		case "price":
			query = query.Order("posts.price ASC").Order("posts.created_at DESC")
		case "price_desc":
			query = query.Order("posts.price DESC").Order("posts.created_at DESC")
		case "following":
			query = query.Order("posts.created_at DESC")
		case "featured":
			if postType != "" && waterSectionFeedID > 0 {
				query = query.Joins("JOIN water_section_featured_posts ON water_section_featured_posts.post_id = posts.id").
					Where("water_section_featured_posts.section_id = ? AND water_section_featured_posts.status = ?", waterSectionFeedID, models.SectionFeaturedStatusActive).
					Order("water_section_featured_posts.created_at DESC")
			} else {
				query = query.Where("posts.is_featured = ?", true).Order("posts.created_at DESC")
			}
		default:
			if searchQuery == "" {
				query = applyWaterSectionPinOrder(query, waterSectionFeedID, now)
				query = applyPinnedOrder(query, now)

				var isTeamTag bool
				if tagIDProvided {
					var tag models.WaterSectionTag
					if h.db.First(&tag, tagID).Error == nil && tag.ContentMode == models.WaterTagModeTeamRecruitment {
						isTeamTag = true
					}
				}
				if isTeamTag && (sort == "all" || sort == "recommend") {
					query = query.Joins("LEFT JOIN water_team_recruitments wtr ON wtr.post_id = posts.id")
					query = query.Order(clause.Expr{SQL: `CASE WHEN wtr.status = ? AND (wtr.deadline IS NULL OR wtr.deadline > ?) THEN 0 WHEN wtr.status = ? THEN 1 ELSE 2 END ASC`, Vars: []interface{}{models.RecruitmentStatusRecruiting, now, models.RecruitmentStatusFull}})
				}
				query = query.Order("posts.created_at DESC")
			}
		}
	}

	query.Session(&gorm.Session{}).Count(&total)

	if isSnapshotting {
		var allIDs []uint
		if isSectionRecommend {
			sectionIDs, sectionErr := services.NewSectionFeedService(h.db, supportsPoll).BuildSnapshot(waterSectionFeedID, postType, now)
			if sectionErr != nil {
				log.Printf("[DB_ERROR] GetList section feed snapshot failed: %v", sectionErr)
				c.JSON(http.StatusInternalServerError, gin.H{"error": "构建版块推荐失败"})
				return
			}
			allIDs = sectionIDs
		} else {
			// 这里必须清除Preload等，单纯Pluck
			snapshotQuery := h.db.Model(&models.Post{}).
				Where("posts.status != ?", models.PostStatusDeleted).
				Where("NOT EXISTS (SELECT 1 FROM water_team_recruitments wtr WHERE wtr.post_id = posts.id)")
			if !supportsPoll {
				snapshotQuery = snapshotQuery.Where("posts.content_kind <> ?", models.PostContentKindPoll)
			}
			if boardIDStr != "" {
				boardID, err := strconv.Atoi(boardIDStr)
				if err == nil {
					snapshotQuery = snapshotQuery.Where("board_id = ?", boardID)
				}
			}
			snapshotQuery = applyPostTypeFilter(snapshotQuery, requestedBoardID, postType)
			if tagIDProvided {
				snapshotQuery = snapshotQuery.Where("water_tag_id = ?", tagID)
			}
			if sort == "all" {
				snapshotQuery = applyWaterSectionPinOrder(snapshotQuery, waterSectionFeedID, now)
				snapshotQuery = applyPinnedOrder(snapshotQuery, now)

				var isTeamTag bool
				if tagIDProvided {
					var tag models.WaterSectionTag
					if h.db.First(&tag, tagID).Error == nil && tag.ContentMode == models.WaterTagModeTeamRecruitment {
						isTeamTag = true
					}
				}
				if isTeamTag {
					snapshotQuery = snapshotQuery.Joins("LEFT JOIN water_team_recruitments wtr ON wtr.post_id = posts.id")
					snapshotQuery = snapshotQuery.Order(clause.Expr{SQL: `CASE WHEN wtr.status = ? AND (wtr.deadline IS NULL OR wtr.deadline > ?) THEN 0 WHEN wtr.status = ? THEN 1 ELSE 2 END ASC`, Vars: []interface{}{models.RecruitmentStatusRecruiting, now, models.RecruitmentStatusFull}})
				}

				snapshotQuery = snapshotQuery.Order(clause.Expr{SQL: "(10.0 + posts.like_count*5 + posts.reply_count*10 + posts.view_count*0.2) / POWER((EXTRACT(EPOCH FROM (? - posts.created_at))/3600.0 + 2), 2) DESC", Vars: []interface{}{now}})
			} else if sort == "hot" {
				snapshotQuery = applyWaterSectionPinOrder(snapshotQuery, waterSectionFeedID, now)
				snapshotQuery = snapshotQuery.Order("(posts.view_count*1 + posts.like_count*20 + posts.reply_count*50) DESC")
			}
			if sort == "hot" {
				snapshotQuery = snapshotQuery.Limit(500)
			}
			if err := snapshotQuery.Pluck("posts.id", &allIDs).Error; err != nil {
				log.Printf("[DB_ERROR] GetList snapshot Pluck failed: %v", err)
				c.JSON(http.StatusInternalServerError, gin.H{"error": "获取帖子列表失败"})
				return
			}
		}

		sessionID = fmt.Sprintf("%d", time.Now().UnixNano())
		ActiveSnapshots.Store(sessionID, Snapshot{
			PostIDs:   allIDs,
			ExpiredAt: time.Now().Add(10 * time.Minute),
			Sort:      sort,
			FeedKind:  genericFeedKind,
		})

		// 自动销毁
		time.AfterFunc(10*time.Minute, func() {
			ActiveSnapshots.Delete(sessionID)
		})

		// 取出第一页
		end := limit
		if end > len(allIDs) {
			end = len(allIDs)
		}
		if len(allIDs) > 0 {
			targetIDs := allIDs[:end]
			var rawPosts []models.Post
			if err := h.db.Model(&models.Post{}).Where("id IN ?", targetIDs).Preload("Author").Preload("Images").Preload("Images.File").Find(&rawPosts).Error; err != nil {
				log.Printf("[DB_ERROR] GetList common feed Find failed: %v", err)
				c.JSON(http.StatusInternalServerError, gin.H{"error": "获取帖子列表失败"})
				return
			}

			postMap := make(map[uint]models.Post)
			for _, p := range rawPosts {
				postMap[p.ID] = p
			}
			for _, id := range targetIDs {
				if p, exists := postMap[id]; exists {
					posts = append(posts, p)
				}
			}
		}
	} else {
		if scene == "loadmore" && (sort == "all" || sort == "hot") {
			c.JSON(http.StatusConflict, gin.H{"error": "信息流已更新，请重新刷新", "code": "feed_session_expired"})
			return
		}
		// 普通查询分页
		if err := query.Offset(offset).Limit(limit).Find(&posts).Error; err != nil {
			c.JSON(http.StatusInternalServerError, gin.H{"error": "获取帖子列表失败"})
			return
		}
	}
	h.hydratePosts(c, posts, now)
	if posts == nil {
		posts = []models.Post{}
	}

	c.JSON(http.StatusOK, gin.H{
		"posts":      posts,
		"total":      total,
		"page":       page,
		"limit":      limit,
		"session_id": sessionID,
	})
}

// 提取共用方法
func (h *PostHandler) fillLikes(c *gin.Context, posts []models.Post) {
	if userID, exists := c.Get("user_id"); exists {
		uid := userID.(uint)
		var postIDs []uint
		for _, p := range posts {
			postIDs = append(postIDs, p.ID)
		}
		if len(postIDs) > 0 {
			var likedPostIDs []uint
			h.db.Model(&models.Like{}).Where("user_id = ? AND target_type = ? AND target_id IN ?", uid, "post", postIDs).Pluck("target_id", &likedPostIDs)
			likedMap := make(map[uint]bool)
			for _, id := range likedPostIDs {
				likedMap[id] = true
			}
			for i := range posts {
				if likedMap[posts[i].ID] {
					posts[i].IsLiked = true
				}
			}
		}
	}
}

func applyWaterSectionPinOrder(query *gorm.DB, sectionID uint, now time.Time) *gorm.DB {
	if sectionID == 0 {
		return query
	}
	return query.
		Joins(
			`LEFT JOIN water_section_pins wsp_active ON wsp_active.post_id = posts.id
				AND wsp_active.section_id = ?
				AND wsp_active.status = ?
				AND (wsp_active.pinned_until IS NULL OR wsp_active.pinned_until > ?)`,
			sectionID,
			models.PinStatusActive,
			now,
		).
		Order("CASE WHEN wsp_active.id IS NULL THEN 1 ELSE 0 END ASC").
		Order("wsp_active.weight DESC").
		Order("wsp_active.created_at DESC NULLS LAST")
}

func (h *PostHandler) fillWaterSectionPinState(posts []models.Post, now time.Time) {
	if len(posts) == 0 {
		return
	}

	postIDs := make([]uint, 0, len(posts))
	slugs := map[string]struct{}{}
	for _, post := range posts {
		if post.BoardID != models.BoardShuitie || post.PostType == "" {
			continue
		}
		postIDs = append(postIDs, post.ID)
		slugs[post.PostType] = struct{}{}
	}
	if len(postIDs) == 0 {
		return
	}

	slugList := make([]string, 0, len(slugs))
	for slug := range slugs {
		slugList = append(slugList, slug)
	}
	var sections []models.WaterSection
	if err := h.db.Where("slug IN ?", slugList).Find(&sections).Error; err != nil {
		return
	}
	sectionIDBySlug := map[string]uint{}
	sectionIDs := make([]uint, 0, len(sections))
	for _, section := range sections {
		sectionIDBySlug[section.Slug] = section.ID
		sectionIDs = append(sectionIDs, section.ID)
	}
	if len(sectionIDs) == 0 {
		return
	}

	var pins []models.WaterSectionPin
	if err := h.db.
		Where("post_id IN ? AND section_id IN ? AND status = ? AND (pinned_until IS NULL OR pinned_until > ?)",
			postIDs, sectionIDs, models.PinStatusActive, now).
		Find(&pins).Error; err != nil {
		return
	}
	pinIDByPostAndSection := map[string]uint{}
	for _, pin := range pins {
		key := fmt.Sprintf("%d:%d", pin.PostID, pin.SectionID)
		pinIDByPostAndSection[key] = pin.ID
	}
	for i := range posts {
		sectionID := sectionIDBySlug[posts[i].PostType]
		if sectionID == 0 {
			continue
		}
		key := fmt.Sprintf("%d:%d", posts[i].ID, sectionID)
		if pinID, ok := pinIDByPostAndSection[key]; ok {
			posts[i].WaterSectionPinned = true
			posts[i].WaterSectionPinID = &pinID
		}
	}
}

func (h *PostHandler) fillWaterSectionFeaturedState(posts []models.Post) {
	if len(posts) == 0 {
		return
	}

	postIDs := make([]uint, 0, len(posts))
	slugs := map[string]struct{}{}
	for _, post := range posts {
		if post.BoardID != models.BoardShuitie || post.PostType == "" {
			continue
		}
		postIDs = append(postIDs, post.ID)
		slugs[post.PostType] = struct{}{}
	}
	if len(postIDs) == 0 {
		return
	}

	slugList := make([]string, 0, len(slugs))
	for slug := range slugs {
		slugList = append(slugList, slug)
	}
	var sections []models.WaterSection
	if err := h.db.Where("slug IN ?", slugList).Find(&sections).Error; err != nil {
		return
	}
	sectionIDBySlug := map[string]uint{}
	sectionIDs := make([]uint, 0, len(sections))
	for _, section := range sections {
		sectionIDBySlug[section.Slug] = section.ID
		sectionIDs = append(sectionIDs, section.ID)
	}
	if len(sectionIDs) == 0 {
		return
	}

	var featureds []models.WaterSectionFeaturedPost
	if err := h.db.
		Where("post_id IN ? AND section_id IN ? AND status = ?",
			postIDs, sectionIDs, models.SectionFeaturedStatusActive).
		Find(&featureds).Error; err != nil {
		return
	}
	featuredIDByPostAndSection := map[string]uint{}
	for _, f := range featureds {
		key := fmt.Sprintf("%d:%d", f.PostID, f.SectionID)
		featuredIDByPostAndSection[key] = f.ID
	}
	var pendingApps []models.FeaturedApplication
	if err := h.db.
		Where("post_id IN ? AND status = ?", postIDs, "pending").
		Find(&pendingApps).Error; err != nil {
		return
	}
	pendingByPost := map[uint]struct{}{}
	for _, app := range pendingApps {
		pendingByPost[app.PostID] = struct{}{}
	}
	for i := range posts {
		sectionID := sectionIDBySlug[posts[i].PostType]
		if sectionID == 0 {
			continue
		}
		key := fmt.Sprintf("%d:%d", posts[i].ID, sectionID)
		if fID, ok := featuredIDByPostAndSection[key]; ok {
			posts[i].WaterSectionFeatured = true
			posts[i].WaterSectionFeaturedID = &fID
		}
		if _, ok := pendingByPost[posts[i].ID]; ok {
			posts[i].HomeFeaturedPending = true
		}
	}
}

// fillWaterSectionAuthorMeta 为水帖帖子的作者填充当前帖子所属版块内的等级与称号。
// 仅当 board_id=BoardShuitie 且 post_type 有效时填充；其余帖子保持 WaterSectionAuthorMeta 为 nil。
func (h *PostHandler) fillWaterSectionAuthorMeta(posts []models.Post) {
	if len(posts) == 0 {
		return
	}

	type userSectionKey struct {
		UserID    uint
		SectionID uint
	}

	postTypeSet := map[string]struct{}{}
	authorSectionSet := map[userSectionKey]struct{}{}
	requireFill := false
	for _, p := range posts {
		if p.BoardID != models.BoardShuitie || p.ContentKind == models.PostContentKindPoll || p.PostType == "" {
			continue
		}
		requireFill = true
		postTypeSet[p.PostType] = struct{}{}
		authorSectionSet[userSectionKey{UserID: p.AuthorID, SectionID: 0}] = struct{}{} // 占位
	}
	if !requireFill {
		return
	}

	// 第一阶段：拉取所有涉及到的 WaterSection（slug → section）
	slugList := make([]string, 0, len(postTypeSet))
	for slug := range postTypeSet {
		slugList = append(slugList, slug)
	}
	var sections []models.WaterSection
	if err := h.db.Where("slug IN ?", slugList).Find(&sections).Error; err != nil {
		return
	}
	sectionBySlug := map[string]models.WaterSection{}
	sectionIDSet := map[uint]struct{}{}
	for _, s := range sections {
		sectionBySlug[s.Slug] = s
		sectionIDSet[s.ID] = struct{}{}
	}
	if len(sectionIDSet) == 0 {
		return
	}

	// 第二阶段：组装实际的 (author, section) 二元组
	authorSectionSet = map[userSectionKey]struct{}{}
	for _, p := range posts {
		if p.BoardID != models.BoardShuitie || p.ContentKind == models.PostContentKindPoll || p.PostType == "" {
			continue
		}
		sec, ok := sectionBySlug[p.PostType]
		if !ok {
			continue
		}
		authorSectionSet[userSectionKey{UserID: p.AuthorID, SectionID: sec.ID}] = struct{}{}
	}
	if len(authorSectionSet) == 0 {
		return
	}

	// 第三阶段：批量查 WaterSectionUserStat
	userIDs := make([]uint, 0, len(authorSectionSet))
	sectionIDs := make([]uint, 0, len(sectionIDSet))
	seenUsers := map[uint]struct{}{}
	for k := range authorSectionSet {
		if _, ok := seenUsers[k.UserID]; !ok {
			seenUsers[k.UserID] = struct{}{}
			userIDs = append(userIDs, k.UserID)
		}
	}
	for id := range sectionIDSet {
		sectionIDs = append(sectionIDs, id)
	}

	var stats []models.WaterSectionUserStat
	if err := h.db.
		Where("user_id IN ? AND section_id IN ?", userIDs, sectionIDs).
		Find(&stats).Error; err != nil {
		return
	}
	statByUserSection := map[userSectionKey]models.WaterSectionUserStat{}
	for _, s := range stats {
		statByUserSection[userSectionKey{UserID: s.UserID, SectionID: s.SectionID}] = s
	}

	// 第四阶段：批量查 WaterSectionLevelTitle（自定义称号），避免 N+1
	// 既然 section 范围有限，按段查询每个 section 的全部 1-8 称号。
	customTitles := map[userSectionKey]string{} // (section, level) → title
	{
		var titles []models.WaterSectionLevelTitle
		if err := h.db.Where("section_id IN ?", sectionIDs).Find(&titles).Error; err == nil {
			for _, t := range titles {
				customTitles[userSectionKey{UserID: t.SectionID, SectionID: uint(t.Level)}] = t.Title
			}
		}
	}

	// 第五阶段：按帖子回填
	for i := range posts {
		p := &posts[i]
		if p.BoardID != models.BoardShuitie || p.ContentKind == models.PostContentKindPoll || p.PostType == "" {
			continue
		}
		sec, ok := sectionBySlug[p.PostType]
		if !ok {
			continue
		}
		key := userSectionKey{UserID: p.AuthorID, SectionID: sec.ID}
		level := 1
		exp := 0
		if stat, found := statByUserSection[key]; found {
			exp = stat.Exp
			level = services.CalculateWaterSectionLevel(exp)
		}
		title := services.DefaultWaterSectionLevelTitle(level)
		if custom, ok := customTitles[userSectionKey{UserID: sec.ID, SectionID: uint(level)}]; ok && custom != "" {
			title = custom
		}
		p.WaterSectionAuthorMeta = &models.WaterSectionAuthorMeta{
			SectionID:    sec.ID,
			SectionSlug:  sec.Slug,
			SectionTitle: sec.Title,
			Level:        level,
			Exp:          exp,
			Title:        title,
		}
	}
}

// getHomeFeedV2 返回独立置顶和普通首页帖子；普通快照不会包含有效置顶。
func (h *PostHandler) getHomeFeedV2(c *gin.Context, sortName, scene, sessionID string, page, limit, offset int, now time.Time, supportsPoll bool) {
	feed := services.NewHomeFeedService(h.db)
	feedKind := "home_v2"
	if supportsPoll {
		feed = services.NewHomeFeedServiceWithPoll(h.db)
		feedKind = "home_v3_poll"
	}
	pinned, err := feed.PinnedPosts(now)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "获取置顶帖子失败"})
		return
	}
	var ids []uint
	algorithm := "home_all_v2"
	if sortName == "time" {
		algorithm = "home_time_v2"
	}
	if supportsPoll {
		algorithm = "home_all_v3_poll"
		if sortName == "time" {
			algorithm = "home_time_v3_poll"
		}
	}
	if sortName == "all" && scene == "loadmore" {
		value, ok := ActiveSnapshots.Load(sessionID)
		if !ok {
			c.JSON(http.StatusConflict, gin.H{"error": "信息流已更新，请重新刷新", "code": "feed_session_expired"})
			return
		}
		snapshot := value.(Snapshot)
		if time.Now().After(snapshot.ExpiredAt) || snapshot.Sort != "all" || snapshot.AlgorithmVersion != algorithm || snapshot.FeedKind != feedKind {
			ActiveSnapshots.Delete(sessionID)
			c.JSON(http.StatusConflict, gin.H{"error": "信息流已更新，请重新刷新", "code": "feed_session_expired"})
			return
		}
		ids = snapshot.PostIDs
	} else if sortName == "all" {
		ids, err = feed.BuildSnapshot(now)
		if err != nil {
			c.JSON(http.StatusInternalServerError, gin.H{"error": "构建首页信息流失败"})
			return
		}
		sessionID = fmt.Sprintf("%d", time.Now().UnixNano())
		ActiveSnapshots.Store(sessionID, Snapshot{PostIDs: ids, ExpiredAt: now.Add(10 * time.Minute), AlgorithmVersion: algorithm, Sort: "all", FeedKind: feedKind})
		time.AfterFunc(10*time.Minute, func() { ActiveSnapshots.Delete(sessionID) })
	} else {
		var normal []models.Post
		err = h.db.Model(&models.Post{}).Where("board_id = ? AND status = ?", models.BoardShuitie, models.PostStatusNormal).
			Where("NOT EXISTS (SELECT 1 FROM water_team_recruitments wtr WHERE wtr.post_id = posts.id)").
			Where("NOT (is_pinned = ? AND (pinned_until IS NULL OR pinned_until > ?))", true, now).
			Scopes(func(db *gorm.DB) *gorm.DB {
				if supportsPoll {
					return db
				}
				return db.Where("content_kind <> ?", models.PostContentKindPoll)
			}).Order("created_at DESC").Limit(500).Find(&normal).Error
		if err != nil {
			c.JSON(http.StatusInternalServerError, gin.H{"error": "获取帖子列表失败"})
			return
		}
		for _, post := range normal {
			ids = append(ids, post.ID)
		}
	}
	end := offset + limit
	if end > len(ids) {
		end = len(ids)
	}
	if offset > len(ids) {
		offset = len(ids)
	}
	pageIDs := ids[offset:end]
	posts, err := h.loadPostsInOrder(pageIDs)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "获取帖子列表失败"})
		return
	}
	h.hydratePosts(c, posts, now)
	h.hydratePosts(c, pinned, now)
	if posts == nil {
		posts = []models.Post{}
	}
	if pinned == nil {
		pinned = []models.Post{}
	}
	c.JSON(http.StatusOK, gin.H{"pinned_posts": pinned, "posts": posts, "total": len(ids), "page": page, "limit": limit, "session_id": sessionID, "algorithm_version": algorithm})
}

func (h *PostHandler) loadPostsInOrder(ids []uint) ([]models.Post, error) {
	if len(ids) == 0 {
		return []models.Post{}, nil
	}
	var raw []models.Post
	if err := h.db.Where("id IN ?", ids).Preload("Author").Preload("Images").Preload("Images.File").Find(&raw).Error; err != nil {
		return nil, err
	}
	byID := make(map[uint]models.Post, len(raw))
	for _, post := range raw {
		byID[post.ID] = post
	}
	ordered := make([]models.Post, 0, len(ids))
	for _, id := range ids {
		if post, ok := byID[id]; ok {
			ordered = append(ordered, post)
		}
	}
	return ordered, nil
}

// getLegacyHomeFeedCompat 兼容旧版本首页请求
func (h *PostHandler) getLegacyHomeFeedCompat(c *gin.Context, scene, sessionID string, page, limit, offset int, now time.Time) {
	feed := services.NewHomeFeedService(h.db)
	pinned, err := feed.PinnedPosts(now)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "获取置顶帖子失败"})
		return
	}

	var ids []uint
	if scene == "loadmore" {
		value, ok := ActiveSnapshots.Load(sessionID)
		if !ok {
			c.JSON(http.StatusConflict, gin.H{"error": "信息流已更新，请重新刷新", "code": "feed_session_expired"})
			return
		}
		snapshot := value.(Snapshot)
		if time.Now().After(snapshot.ExpiredAt) || snapshot.FeedKind != "legacy_hot" {
			ActiveSnapshots.Delete(sessionID)
			c.JSON(http.StatusConflict, gin.H{"error": "信息流已更新，请重新刷新", "code": "feed_session_expired"})
			return
		}
		ids = snapshot.PostIDs
	} else {
		ids, err = feed.BuildSnapshot(now)
		if err != nil {
			c.JSON(http.StatusInternalServerError, gin.H{"error": "构建首页信息流失败"})
			return
		}

		// 把置顶帖的ID放在前面
		var finalIDs []uint
		seen := map[uint]bool{}
		for _, p := range pinned {
			finalIDs = append(finalIDs, p.ID)
			seen[p.ID] = true
		}
		for _, id := range ids {
			if !seen[id] {
				finalIDs = append(finalIDs, id)
				seen[id] = true
			}
		}
		ids = finalIDs

		sessionID = fmt.Sprintf("%d", time.Now().UnixNano())
		ActiveSnapshots.Store(sessionID, Snapshot{PostIDs: ids, ExpiredAt: now.Add(10 * time.Minute), Sort: "all", FeedKind: "legacy_hot"})
		time.AfterFunc(10*time.Minute, func() { ActiveSnapshots.Delete(sessionID) })
	}

	end := offset + limit
	if end > len(ids) {
		end = len(ids)
	}
	if offset > len(ids) {
		offset = len(ids)
	}
	pageIDs := ids[offset:end]
	posts, err := h.loadPostsInOrder(pageIDs)
	if err != nil {
		log.Printf("[DB_ERROR] legacy home feed load posts: %v", err)
		c.JSON(http.StatusInternalServerError, gin.H{
			"error": "获取首页帖子失败",
			"code":  "home_feed_query_failed",
		})
		return
	}
	h.hydratePosts(c, posts, now)
	if posts == nil {
		posts = []models.Post{}
	}
	c.JSON(http.StatusOK, gin.H{
		"posts":      posts,
		"total":      len(ids),
		"page":       page,
		"limit":      limit,
		"session_id": sessionID,
	})
}

// CreatePostInput 创建帖子输入
type CreatePostInput struct {
	Title           string  `form:"title"`
	Content         string  `form:"content" binding:"required"`
	BoardID         int     `form:"board_id" binding:"required"`
	PostType        string  `form:"post_type"`
	Price           float64 `form:"price"`
	Contact         string  `form:"contact"`
	ContactType     string  `form:"contact_type"`
	MarketTags      string  `form:"market_tags"`
	WaterTagID      *uint   `form:"water_tag_id"`
	TeamNeededCount int     `form:"team_needed_count"`
	TeamRolesJSON   string  `form:"team_roles_json"`
	TeamDeadline    string  `form:"team_deadline"`
}

// Create 创建帖子
func (h *PostHandler) Create(c *gin.Context) {
	userID, _ := c.Get("user_id")

	var input CreatePostInput
	if err := c.ShouldBind(&input); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
		return
	}
	fileIDsRaw := c.PostForm("file_ids")
	if fileIDsRaw == "" {
		fileIDsRaw = c.PostForm("file_ids[]")
	}
	if fileIDsRaw == "" && c.Request.MultipartForm != nil {
		for key, values := range c.Request.MultipartForm.Value {
			if strings.Contains(key, "file_ids") && len(values) > 0 {
				fileIDsRaw = values[0]
				break
			}
		}
	}
	fileIDs, err := services.ParseImageFileIDs(fileIDsRaw)
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
		return
	}
	if models.BoardID(input.BoardID) == models.BoardShuitie && strings.TrimSpace(input.PostType) == "poll" {
		c.JSON(http.StatusBadRequest, gin.H{"code": "poll_requires_poll_api", "error": "请使用投票发布接口"})
		return
	}

	var user models.User
	if err := h.db.Select("id", "student_verified_at", "edu_bound").First(&user, userID).Error; err != nil {
		c.JSON(http.StatusUnauthorized, gin.H{"error": "用户不存在"})
		return
	}
	if models.BoardID(input.BoardID) == models.BoardMarket && !user.IsStudentVerified() {
		c.JSON(http.StatusForbidden, gin.H{"error": "毕业用户仅可发布普通帖子，不能在集市发帖"})
		return
	}

	normalizedType, err := normalizeWaterPostType(models.BoardID(input.BoardID), input.PostType)
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "无效的水帖分类"})
		return
	}
	contactType, contact, err := normalizeMarketContact(
		models.BoardID(input.BoardID),
		input.ContactType,
		input.Contact,
	)
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
		return
	}

	// 先创建帖子
	now := time.Now()
	post := models.Post{
		Title:          input.Title,
		Content:        input.Content,
		BoardID:        models.BoardID(input.BoardID),
		AuthorID:       userID.(uint),
		PostType:       normalizedType,
		ContentKind:    models.PostContentKindNormal,
		Price:          input.Price,
		ContactType:    contactType,
		Contact:        contact,
		MarketTags:     normalizeMarketTags(input.MarketTags),
		Status:         models.PostStatusNormal,
		CreatedAt:      now,
		LastActivityAt: now,
	}

	// 水帖版块额外校验版块活跃状态与标签归属
	var sectionIDPtr *uint
	var isTeamRecruitment bool
	var roles []string
	var parsedDeadline *time.Time
	var rolesJSON string

	if post.BoardID == models.BoardShuitie {
		sectionID, secErr := validateWaterSectionActive(h.db, normalizedType)
		if secErr != nil {
			c.JSON(http.StatusBadRequest, gin.H{"error": secErr.Error()})
			return
		}
		sectionIDPtr = &sectionID
		// 禁言检查：admin/super_admin 可绕过
		role, _ := c.Get("role")
		if role != "admin" && role != "super_admin" {
			permSvc := services.NewWaterPermissionService(h.db)
			if permSvc.IsMuted(sectionID, userID.(uint)) {
				c.JSON(http.StatusForbidden, gin.H{"error": "你已被该版块禁言，暂时无法发布内容"})
				return
			}
		}
		if input.WaterTagID != nil && *input.WaterTagID != 0 {
			if tagErr := validateWaterTagBelongsToSection(h.db, *input.WaterTagID, sectionID); tagErr != nil {
				c.JSON(http.StatusBadRequest, gin.H{"error": tagErr.Error()})
				return
			}
			post.WaterTagID = input.WaterTagID

			var tag models.WaterSectionTag
			if err := h.db.First(&tag, *post.WaterTagID).Error; err == nil {
				if tag.ContentMode == models.WaterTagModeTeamRecruitment {
					isTeamRecruitment = true
					validRoles, pdl, err := validateTeamFields(input.TeamNeededCount, input.TeamRolesJSON, input.TeamDeadline)
					if err != nil {
						c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
						return
					}
					roles = validRoles
					parsedDeadline = pdl
					bytes, _ := json.Marshal(roles)
					rolesJSON = string(bytes)
				} else {
					if input.TeamNeededCount != 0 || input.TeamRolesJSON != "" || input.TeamDeadline != "" {
						c.JSON(http.StatusBadRequest, gin.H{"error": "普通栏目不能提交组队招募字段"})
						return
					}
				}
			}
		}
	}

	err = h.db.Transaction(func(tx *gorm.DB) error {
		if _, err := services.ValidateImageFileIDs(tx, fileIDs, 9, userID.(uint)); err != nil {
			return err
		}
		if err := tx.Create(&post).Error; err != nil {
			return err
		}

		if isTeamRecruitment && sectionIDPtr != nil {
			recruitment := models.WaterTeamRecruitment{
				PostID:      post.ID,
				SectionID:   *sectionIDPtr,
				TagID:       *post.WaterTagID,
				NeededCount: input.TeamNeededCount,
				RolesJSON:   rolesJSON,
				Deadline:    parsedDeadline,
				Status:      models.RecruitmentStatusRecruiting,
			}
			if err := tx.Create(&recruitment).Error; err != nil {
				return err
			}
		}

		if len(fileIDs) > 0 {
			for i, fileID := range fileIDs {
				postImage := models.PostImage{
					PostID:    post.ID,
					FileID:    fileID,
					SortOrder: i,
				}
				if err := tx.Create(&postImage).Error; err != nil {
					return err
				}
			}
		}
		return nil
	})

	if err != nil {
		if errors.Is(err, services.ErrInvalidImageFileReference) {
			c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
			return
		}
		log.Printf("创建帖子失败: %v (user_id=%v, board_id=%v)", err, userID, input.BoardID)
		c.JSON(http.StatusInternalServerError, gin.H{"error": fmt.Sprintf("创建帖子失败: %v", err)})
		return
	}

	// 发放每日首发经验 (全局 + 版块)
	awards := make([]models.ExpAward, 0, 2)
	awarded, globalAward, expErr := services.AwardDailyGlobalExp(h.db, userID.(uint), services.GlobalActionPostDaily, services.GlobalExpPostDaily, "post", post.ID)
	if expErr != nil {
		log.Printf("[EXP_AWARD] global post_daily failed user=%v post_id=%d err=%v", userID, post.ID, expErr)
	} else if awarded && globalAward != nil {
		awards = append(awards, *globalAward)
	}

	if post.BoardID == models.BoardShuitie && post.PostType != "" {
		var section models.WaterSection
		if secErr := h.db.Where("slug = ?", post.PostType).First(&section).Error; secErr == nil && section.ID != 0 {
			secAwarded, secAward, secErr := services.AwardDailySectionExp(h.db, userID.(uint), section.ID, section.Slug, section.Title, services.GlobalActionPostDaily, services.GlobalExpPostDaily, "post", post.ID)
			if secErr != nil {
				log.Printf("[EXP_AWARD] section post_daily failed user=%v section=%d post_id=%d err=%v", userID, section.ID, post.ID, secErr)
			} else if secAwarded && secAward != nil {
				awards = append(awards, *secAward)
			}
		}
	}

	if len(awards) > 0 {
		post.ExpAwards = awards
		for _, award := range awards {
			if award.Scope == "global" {
				post.ExpEarned = award.Exp
			}
		}
	}

	// 图片处理已移至事务内

	if err := h.db.Preload("Author").Preload("Images").Preload("Images.File").First(&post, post.ID).Error; err != nil {
		log.Printf("[DB_WARN] Failed to re-fetch post with preloads after create: %v", err)
	}

	responsePosts := []models.Post{post}
	h.hydratePosts(c, responsePosts, time.Now())

	c.JSON(http.StatusCreated, responsePosts[0])
}

// GetOne 获取帖子详情
func (h *PostHandler) GetOne(c *gin.Context) {
	idStr := c.Param("id")
	id, err := strconv.ParseUint(idStr, 10, 64)
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "无效的帖子ID"})
		return
	}

	var post models.Post
	if err := h.db.Preload("Author").Preload("Images").Preload("Images.File").First(&post, id).Error; err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "帖子不存在"})
		return
	}
	if post.Status == models.PostStatusDeleted {
		userID, loggedIn := c.Get("user_id")
		role, _ := c.Get("role")
		if !loggedIn || (userID.(uint) != post.AuthorID && role != "admin" && role != "super_admin") {
			c.JSON(http.StatusNotFound, gin.H{"error": "帖子不存在"})
			return
		}
	}

	// 增加观看次数
	h.db.Model(&post).UpdateColumn("view_count", gorm.Expr("view_count + 1"))
	post.ViewCount++

	responsePosts := []models.Post{post}
	h.hydratePosts(c, responsePosts, time.Now())
	post = responsePosts[0]
	c.JSON(http.StatusOK, post)
}

// UpdatePostInput 更新帖子输入
type UpdatePostInput struct {
	Title           string  `form:"title"`
	Content         string  `form:"content"`
	PostType        string  `form:"post_type"`
	Price           float64 `form:"price"`
	Contact         string  `form:"contact"`
	ContactType     string  `form:"contact_type"`
	MarketTags      string  `form:"market_tags"`
	WaterTagID      *uint   `form:"water_tag_id"`
	TeamNeededCount int     `form:"team_needed_count"`
	TeamRolesJSON   string  `form:"team_roles_json"`
	TeamDeadline    string  `form:"team_deadline"`
}

// Update 更新帖子
func (h *PostHandler) Update(c *gin.Context) {
	userID, _ := c.Get("user_id")
	role, _ := c.Get("role")
	idStr := c.Param("id")
	id, err := strconv.ParseUint(idStr, 10, 64)
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "无效的帖子ID"})
		return
	}

	var input UpdatePostInput
	if err := c.ShouldBind(&input); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
		return
	}
	fileIDsRaw, replaceImages := c.GetPostForm("file_ids")
	var fileIDs []uint
	if replaceImages {
		fileIDs, err = services.ParseImageFileIDs(fileIDsRaw)
		if err != nil {
			c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
			return
		}
	}

	var post models.Post
	err = h.db.Transaction(func(tx *gorm.DB) error {
		if err := tx.Clauses(clause.Locking{Strength: "UPDATE"}).First(&post, id).Error; err != nil {
			return fmt.Errorf("post_not_found")
		}
		if post.ContentKind == models.PostContentKindPoll {
			return fmt.Errorf("poll_requires_poll_api")
		}

		// 只有作者或管理员可以更新
		if post.AuthorID != userID.(uint) && role != "admin" && role != "super_admin" {
			return fmt.Errorf("unauthorized")
		}
		if replaceImages {
			if _, err := services.ValidateImageFileIDs(tx, fileIDs, 9, userID.(uint)); err != nil {
				return err
			}
		}

		var user models.User
		if err := tx.Select("id", "student_verified_at", "edu_bound").First(&user, userID).Error; err != nil {
			return fmt.Errorf("user_not_found")
		}
		if post.BoardID == models.BoardMarket && !user.IsStudentVerified() {
			return fmt.Errorf("market_graduated")
		}

		normalizedType, err := normalizeWaterPostType(post.BoardID, input.PostType)
		if err != nil {
			return fmt.Errorf("invalid_post_type")
		}
		var contactType models.MarketContactType
		var contact string
		if post.BoardID == models.BoardMarket &&
			post.ContactType == models.MarketContactTypeOther &&
			models.MarketContactType(strings.TrimSpace(input.ContactType)) == models.MarketContactTypeOther &&
			strings.TrimSpace(input.Contact) == post.Contact {
			// 历史 other 类型只允许原样保留；修改账号时必须选择结构化类型。
			contactType = models.MarketContactTypeOther
			contact = post.Contact
		} else {
			contactType, contact, err = normalizeMarketContact(post.BoardID, input.ContactType, input.Contact)
			if err != nil {
				return err
			}
		}

		updates := map[string]interface{}{
			"title":        input.Title,
			"content":      input.Content,
			"post_type":    normalizedType,
			"price":        input.Price,
			"contact_type": contactType,
			"contact":      contact,
			"market_tags":  normalizeMarketTags(input.MarketTags),
		}

		var isOriginalTeam bool
		var isNewTeam bool
		var originalRecruitment models.WaterTeamRecruitment
		var sectionID uint

		if post.BoardID == models.BoardShuitie {
			var secErr error
			sectionID, secErr = validateWaterSectionActive(tx, normalizedType)
			if secErr != nil {
				return secErr
			}

			if role != "admin" && role != "super_admin" {
				permSvc := services.NewWaterPermissionService(tx)
				if permSvc.IsMuted(sectionID, userID.(uint)) {
					return fmt.Errorf("user_muted")
				}
			}

			if post.WaterTagID != nil {
				var origTag models.WaterSectionTag
				if err := tx.First(&origTag, *post.WaterTagID).Error; err == nil && origTag.ContentMode == models.WaterTagModeTeamRecruitment {
					isOriginalTeam = true
					if err := tx.Clauses(clause.Locking{Strength: "UPDATE"}).Where("post_id = ?", post.ID).First(&originalRecruitment).Error; err != nil {
						if errors.Is(err, gorm.ErrRecordNotFound) {
							return fmt.Errorf("recruitment_missing")
						}
						return err
					}
				}
			}

			finalTagID := post.WaterTagID
			if input.WaterTagID != nil {
				finalTagID = input.WaterTagID
			}

			if finalTagID != nil && *finalTagID != 0 {
				if tagErr := validateWaterTagBelongsToSection(tx, *finalTagID, sectionID); tagErr != nil {
					return tagErr
				}
				updates["water_tag_id"] = finalTagID

				var newTag models.WaterSectionTag
				if err := tx.First(&newTag, *finalTagID).Error; err == nil && newTag.ContentMode == models.WaterTagModeTeamRecruitment {
					isNewTeam = true
				}
			} else if input.WaterTagID != nil {
				updates["water_tag_id"] = nil
			}

			if isOriginalTeam != isNewTeam {
				return fmt.Errorf("cannot_switch_team_mode")
			}

			if isNewTeam {
				var acceptedCount int64
				if err := tx.Model(&models.WaterTeamApplication{}).
					Where("recruitment_id = ? AND status = ?", originalRecruitment.ID, models.ApplicationStatusAccepted).
					Count(&acceptedCount).Error; err != nil {
					return err
				}

				if input.TeamNeededCount < int(acceptedCount) {
					return fmt.Errorf("招募人数不能低于已同意人数（%d）", acceptedCount)
				}

				validRoles, pdl, err := validateTeamFields(input.TeamNeededCount, input.TeamRolesJSON, input.TeamDeadline)
				if err != nil {
					return err
				}
				bytes, _ := json.Marshal(validRoles)
				rolesJSON := string(bytes)

				newStatus := originalRecruitment.Status
				if originalRecruitment.Status == models.RecruitmentStatusFull && input.TeamNeededCount > int(acceptedCount) {
					newStatus = models.RecruitmentStatusRecruiting
				} else if originalRecruitment.Status == models.RecruitmentStatusExpired && pdl != nil && pdl.After(time.Now()) {
					if input.TeamNeededCount > int(acceptedCount) {
						newStatus = models.RecruitmentStatusRecruiting
					} else {
						newStatus = models.RecruitmentStatusFull
					}
				}

				if err := tx.Model(&originalRecruitment).Updates(map[string]interface{}{
					"needed_count":   input.TeamNeededCount,
					"roles_json":     rolesJSON,
					"deadline":       pdl,
					"status":         newStatus,
					"accepted_count": int(acceptedCount),
				}).Error; err != nil {
					return fmt.Errorf("update_recruitment_failed")
				}
			} else {
				if input.TeamNeededCount != 0 || input.TeamRolesJSON != "" || input.TeamDeadline != "" {
					return fmt.Errorf("invalid_team_fields")
				}
			}
		}

		if err := tx.Model(&post).Updates(updates).Error; err != nil {
			return fmt.Errorf("update_post_failed")
		}

		if replaceImages {
			if err := tx.Where("post_id = ?", post.ID).Delete(&models.PostImage{}).Error; err != nil {
				return fmt.Errorf("update_images_failed")
			}
			if len(fileIDs) > 0 {
				for i, fileID := range fileIDs {
					postImage := models.PostImage{
						PostID:    post.ID,
						FileID:    fileID,
						SortOrder: i,
					}
					if err := tx.Create(&postImage).Error; err != nil {
						log.Printf("更新 PostImage 失败: post_id=%d, file_id=%d, err=%v", post.ID, fileID, err)
						return fmt.Errorf("update_images_failed")
					}
				}
			}
		}

		return nil
	})

	if err != nil {
		if errors.Is(err, services.ErrInvalidImageFileReference) {
			c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
			return
		}
		switch err.Error() {
		case "post_not_found":
			c.JSON(http.StatusNotFound, gin.H{"error": "帖子不存在"})
		case "poll_requires_poll_api":
			c.JSON(http.StatusBadRequest, gin.H{"code": "poll_requires_poll_api", "error": "投票内容请使用投票编辑接口"})
		case "unauthorized":
			c.JSON(http.StatusForbidden, gin.H{"error": "无权限"})
		case "user_not_found":
			c.JSON(http.StatusUnauthorized, gin.H{"error": "用户不存在"})
		case "market_graduated":
			c.JSON(http.StatusForbidden, gin.H{"error": "毕业用户不能编辑集市帖子"})
		case "invalid_post_type":
			c.JSON(http.StatusBadRequest, gin.H{"error": "无效的水帖分类"})
		case "user_muted":
			c.JSON(http.StatusForbidden, gin.H{"error": "你已被该版块禁言，暂时无法编辑内容"})
		case "cannot_switch_team_mode":
			c.JSON(http.StatusBadRequest, gin.H{"error": "不能在普通帖子和组队帖子之间切换"})
		case "invalid_team_fields":
			c.JSON(http.StatusBadRequest, gin.H{"error": "普通栏目不能提交组队招募字段"})
		case "update_recruitment_failed":
			c.JSON(http.StatusInternalServerError, gin.H{"error": "更新招募信息失败"})
		case "update_post_failed":
			c.JSON(http.StatusInternalServerError, gin.H{"error": "更新帖子失败"})
		case "update_images_failed":
			c.JSON(http.StatusInternalServerError, gin.H{"error": "更新帖子图片失败"})
		case "recruitment_missing":
			log.Printf("[TEAM_RECRUITMENT] post_id=%d missing recruitment record", post.ID)
			c.JSON(http.StatusInternalServerError, gin.H{"error": "组队招募数据异常，请稍后重试"})
		default:
			// Let validation errors pass through
			c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
		}
		return
	}

	if err := h.db.Preload("Author").Preload("Images").Preload("Images.File").First(&post, post.ID).Error; err != nil {
		log.Printf("[DB_WARN] Failed to re-fetch post with preloads after update: %v", err)
	}

	responsePosts := []models.Post{post}
	h.hydratePosts(c, responsePosts, time.Now())

	c.JSON(http.StatusOK, responsePosts[0])
}

type UpdatePostStatusInput struct {
	Status models.PostStatus `json:"status" binding:"required"`
}

// UpdateStatus 更新集市帖状态。成交状态只保留记录，不等同删除发布。
func (h *PostHandler) UpdateStatus(c *gin.Context) {
	userIDAny, _ := c.Get("user_id")
	userID := userIDAny.(uint)

	id, err := strconv.ParseUint(c.Param("id"), 10, 64)
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "无效的帖子ID"})
		return
	}

	var input UpdatePostStatusInput
	if err := c.ShouldBindJSON(&input); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
		return
	}
	if input.Status != models.PostStatusNormal &&
		input.Status != models.PostStatusSold &&
		input.Status != models.PostStatusClosed {
		c.JSON(http.StatusBadRequest, gin.H{"error": "无效的帖子状态"})
		return
	}

	var post models.Post
	if err := h.db.First(&post, id).Error; err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "帖子不存在"})
		return
	}
	if post.ContentKind == models.PostContentKindPoll {
		c.JSON(http.StatusBadRequest, gin.H{"code": "poll_requires_poll_api", "error": "投票状态不能通过普通帖子接口修改"})
		return
	}
	if post.AuthorID != userID {
		c.JSON(http.StatusForbidden, gin.H{"error": "只能修改自己的发布"})
		return
	}
	if post.BoardID != models.BoardMarket {
		c.JSON(http.StatusBadRequest, gin.H{"error": "只有集市发布可以修改状态"})
		return
	}
	if input.Status == models.PostStatusSold && post.PostType != "sell" {
		c.JSON(http.StatusBadRequest, gin.H{"error": "只有出售商品可以标记已售出"})
		return
	}

	if err := h.db.Model(&post).Update("status", input.Status).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "更新状态失败"})
		return
	}
	if err := h.db.
		Preload("Author").
		Preload("Images").
		Preload("Images.File").
		First(&post, id).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "重新获取帖子失败"})
		return
	}

	c.JSON(http.StatusOK, post)
}

// Delete 删除帖子
func (h *PostHandler) Delete(c *gin.Context) {
	userID, _ := c.Get("user_id")
	role, _ := c.Get("role")
	idStr := c.Param("id")
	id, err := strconv.ParseUint(idStr, 10, 64)
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "无效的帖子ID"})
		return
	}

	var post models.Post
	if err := h.db.First(&post, id).Error; err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "帖子不存在"})
		return
	}
	if post.ContentKind == models.PostContentKindPoll {
		c.JSON(http.StatusBadRequest, gin.H{"code": "poll_requires_poll_api", "error": "投票内容请使用投票删除接口"})
		return
	}

	// 只有作者或管理员可以删除
	if post.AuthorID != userID.(uint) && role != "admin" && role != "super_admin" {
		c.JSON(http.StatusForbidden, gin.H{"error": "无权限"})
		return
	}

	if err := h.db.Model(&post).Update("status", models.PostStatusDeleted).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "数据库操作失败"})
		return
	}

	// 记录管理员操作 & 增加管理员经验
	if role == "admin" || role == "super_admin" {
		var u models.User
		h.db.Select("nickname").First(&u, userID)
		if err := h.db.Create(&models.AdminLog{
			AdminID: userID.(uint), AdminName: u.Nickname,
			Action: "删除帖子", Target: post.Title,
		}).Error; err != nil {
			log.Printf("[DB_WARN] Failed to write admin log: %v", err)
		}
		// 管理员每使用一次管理权限，经验+1
		if err := h.db.Model(&models.User{}).Where("id = ?", userID).UpdateColumn("admin_exp", gorm.Expr("COALESCE(admin_exp, 0) + 1")).Error; err != nil {
			log.Printf("[DB_WARN] Failed to update admin_exp: %v", err)
		}
	}

	c.JSON(http.StatusOK, gin.H{"message": "删除成功"})
}

// hydratePosts 统一对返回的 Post 进行关联数据和状态填充
func (h *PostHandler) hydratePosts(c *gin.Context, posts []models.Post, now time.Time) {
	if len(posts) == 0 {
		return
	}

	h.fillLikes(c, posts)
	h.fillWaterSectionPinState(posts, now)
	h.fillWaterSectionFeaturedState(posts)
	h.fillWaterSectionAuthorMeta(posts)
	h.fillTeamRecruitmentMeta(c, posts, now)
	if supportsPollRequest(c) {
		_ = services.NewPollService(h.db).HydratePollPosts(posts, contextUserID(c))
	}
}

func (h *PostHandler) fillTeamRecruitmentMeta(c *gin.Context, posts []models.Post, now time.Time) {
	var teamPostIDs []uint
	for _, p := range posts {
		if p.BoardID == models.BoardShuitie && p.ContentKind != models.PostContentKindPoll {
			teamPostIDs = append(teamPostIDs, p.ID)
		}
	}
	if len(teamPostIDs) == 0 {
		return
	}

	var recruitments []models.WaterTeamRecruitment
	if err := h.db.Where("post_id IN ?", teamPostIDs).Find(&recruitments).Error; err != nil {
		log.Printf("fillTeamRecruitmentMeta 获取招募信息失败: %v", err)
		return
	}
	if len(recruitments) == 0 {
		return
	}

	recMap := make(map[uint]models.WaterTeamRecruitment)
	var recIDs []uint
	for _, r := range recruitments {
		recMap[r.PostID] = r
		recIDs = append(recIDs, r.ID)
	}

	// Fetch application counts
	type AppCount struct {
		RecruitmentID uint
		Count         int64
	}
	var appCounts []AppCount
	if err := h.db.Model(&models.WaterTeamApplication{}).
		Select("recruitment_id, count(*) as count").
		Where("recruitment_id IN ?", recIDs).
		Group("recruitment_id").
		Find(&appCounts).Error; err != nil {
		log.Printf("fillTeamRecruitmentMeta 获取申请数量失败: %v", err)
	}
	countMap := make(map[uint]int64)
	for _, c := range appCounts {
		countMap[c.RecruitmentID] = c.Count
	}

	var userID uint
	if v, exists := c.Get("user_id"); exists {
		userID = v.(uint)
	}

	var myApps []models.WaterTeamApplication
	if userID != 0 {
		h.db.Where("recruitment_id IN ? AND applicant_id = ?", recIDs, userID).Find(&myApps)
	}
	myAppMap := make(map[uint]string)
	for _, app := range myApps {
		myAppMap[app.RecruitmentID] = app.Status
	}

	for i := range posts {
		p := &posts[i]
		rec, ok := recMap[p.ID]
		if !ok {
			continue
		}
		var roles []string
		json.Unmarshal([]byte(rec.RolesJSON), &roles)

		effectiveStatus := models.EffectiveRecruitmentStatus(rec, now)
		var myStatus *string
		if s, ok := myAppMap[rec.ID]; ok {
			statusCopy := s
			myStatus = &statusCopy
		}

		isOwner := false
		if userID != 0 && userID == p.AuthorID {
			isOwner = true
		}

		canApply := false
		if !isOwner && userID != 0 && effectiveStatus == models.RecruitmentStatusRecruiting {
			// 如果没有申请，或者申请被取消/拒绝了，可以申请
			if myStatus == nil || *myStatus == models.ApplicationStatusCancelled || *myStatus == models.ApplicationStatusRejected {
				canApply = true
			}
		}

		p.TeamRecruitmentMeta = &models.TeamRecruitmentMeta{
			RecruitmentID:       rec.ID,
			NeededCount:         rec.NeededCount,
			AcceptedCount:       rec.AcceptedCount,
			RemainingCount:      rec.NeededCount - rec.AcceptedCount,
			Roles:               roles,
			Deadline:            rec.Deadline,
			Status:              rec.Status,
			EffectiveStatus:     effectiveStatus,
			ApplicationCount:    countMap[rec.ID],
			MyApplicationStatus: myStatus,
			IsOwner:             isOwner,
			CanApply:            canApply,
			CanManage:           isOwner,
		}
	}
}

func validateTeamFields(neededCount int, rolesJSON string, deadline string) ([]string, *time.Time, error) {
	if neededCount < 1 || neededCount > 20 {
		return nil, nil, fmt.Errorf("招募人数必须在 1~20 之间")
	}
	var roles []string
	if err := json.Unmarshal([]byte(rolesJSON), &roles); err != nil {
		return nil, nil, fmt.Errorf("招募方向格式错误")
	}
	if len(roles) < 1 || len(roles) > 8 {
		return nil, nil, fmt.Errorf("招募方向必须在 1~8 项之间")
	}
	seen := make(map[string]bool)
	var finalRoles []string
	for _, r := range roles {
		r = strings.TrimSpace(r)
		if r == "" {
			continue
		}
		if utf8.RuneCountInString(r) > 20 {
			return nil, nil, fmt.Errorf("招募方向单项不能超过 20 字")
		}
		if !seen[r] {
			seen[r] = true
			finalRoles = append(finalRoles, r)
		}
	}
	if len(finalRoles) < 1 {
		return nil, nil, fmt.Errorf("至少需要填写一个有效的招募方向")
	}

	var parsedDeadline *time.Time
	if deadline != "" {
		t, err := time.Parse(time.RFC3339, deadline)
		if err != nil {
			return nil, nil, fmt.Errorf("截止时间格式错误 (需要 RFC3339 格式)")
		}
		if t.Before(time.Now()) {
			return nil, nil, fmt.Errorf("截止时间必须在未来")
		}
		parsedDeadline = &t
	}
	return finalRoles, parsedDeadline, nil
}
