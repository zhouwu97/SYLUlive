import sys

with open('e:/AI/xynewui/server/internal/handlers/post.go', 'r', encoding='utf-8') as f:
    lines = f.readlines()

start_idx = -1
end_idx = -1
for i, line in enumerate(lines):
    if line.startswith('// GetList '):
        start_idx = i
    if start_idx != -1 and line.startswith('// CreatePostInput '):
        end_idx = i
        break

if start_idx != -1 and end_idx != -1:
    new_getlist = """
// Snapshot 帖子快照
type Snapshot struct {
	PostIDs   []uint
	ExpiredAt time.Time
}

var ActiveSnapshots sync.Map // key: session_id (string), value: Snapshot

// GetList 获取帖子列表
func (h *PostHandler) GetList(c *gin.Context) {
	boardIDStr := c.Query("board")
	postType := c.Query("type")
	searchQuery := strings.TrimSpace(strings.ToLower(c.Query("q")))
	sort := c.DefaultQuery("sort", "time")
	pageStr := c.DefaultQuery("page", "1")
	limitStr := c.DefaultQuery("limit", "20")
	sinceStr := c.Query("since")
	
	scene := c.Query("scene") // refresh 或 loadmore
	sessionID := c.Query("session_id")
	offsetStr := c.Query("offset")

	page, _ := strconv.Atoi(pageStr)
	limit, _ := strconv.Atoi(limitStr)
	offset, _ := strconv.Atoi(offsetStr)
	if page < 1 {
		page = 1
	}
	if limit < 1 || limit > 50 {
		limit = 20
	}
	
	// 如果是常规分页（没有传入scene或者只是普通请求），默认使用 offset
	if scene == "" && offset == 0 {
		offset = (page - 1) * limit
	}

	var posts []models.Post
	var total int64

	// 如果是加载更多，并且带有有效的 session_id，尝试走快照
	if scene == "loadmore" && sessionID != "" {
		if val, ok := ActiveSnapshots.Load(sessionID); ok {
			snapshot := val.(Snapshot)
			if time.Now().Before(snapshot.ExpiredAt) {
				// 计算切片边界
				end := offset + limit
				if offset < len(snapshot.PostIDs) {
					if end > len(snapshot.PostIDs) {
						end = len(snapshot.PostIDs)
					}
					targetIDs := snapshot.PostIDs[offset:end]
					
					if len(targetIDs) > 0 {
						var rawPosts []models.Post
						h.db.Model(&models.Post{}).Where("id IN ?", targetIDs).Preload("Author").Preload("Images").Preload("Images.File").Find(&rawPosts)
						
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
					h.fillLikes(c, posts)
					c.JSON(http.StatusOK, gin.H{
						"posts": posts,
						"total": len(snapshot.PostIDs),
						"page":  page,
						"limit": limit,
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
	query := h.db.Model(&models.Post{}).Where("status != ?", models.PostStatusDeleted).Preload("Author").Preload("Images").Preload("Images.File")

	if boardIDStr != "" {
		boardID, err := strconv.Atoi(boardIDStr)
		if err == nil {
			query = query.Where("board_id = ?", boardID)
		}
	}

	if postType != "" {
		query = query.Where("post_type = ?", postType)
	}

	if sinceStr != "" {
		sinceTime, err := time.Parse(time.RFC3339, sinceStr)
		if err == nil {
			query = query.Where("updated_at > ?", sinceTime)
		}
	}

	if searchQuery != "" {
		searchLike := "%" + searchQuery + "%"
		query = query.Where(
			"(LOWER(title) LIKE ? OR LOWER(content) LIKE ?)",
			searchLike,
			searchLike,
		)
		query = query.Order(clause.Expr{
			SQL: `CASE
				WHEN LOWER(title) = ? THEN 0
				WHEN LOWER(title) LIKE ? THEN 1
				WHEN LOWER(title) LIKE ? THEN 2
				WHEN LOWER(content) LIKE ? THEN 3
				ELSE 4
			END,
			POSITION(? IN LOWER(title)),
			CHAR_LENGTH(title)`,
			Vars: []interface{}{
				searchQuery,
				searchQuery + "%",
				searchLike,
				searchLike,
				searchQuery,
			},
		})
	}

	// 动态算法拦截
	isSnapshotting := false
	if scene == "refresh" && (sort == "all" || sort == "hot") && searchQuery == "" && sinceStr == "" {
		isSnapshotting = true
		if sort == "all" {
			query = query.Order("(like_count*5 + reply_count*10 + view_count*0.2) / (((strftime('%s','now') - strftime('%s',created_at))/3600.0 + 2) * ((strftime('%s','now') - strftime('%s',created_at))/3600.0 + 2)) DESC")
		} else if sort == "hot" {
			query = query.Order("(view_count*1 + like_count*20 + reply_count*50) DESC")
		}
	} else {
		// 常规排序
		switch sort {
		case "price":
			query = query.Order("price ASC").Order("created_at DESC")
		case "price_desc":
			query = query.Order("price DESC").Order("created_at DESC")
		default:
			query = query.Order("created_at DESC")
		}
	}

	query.Count(&total)

	if isSnapshotting {
		var allIDs []uint
		// 这里必须清除Preload等，单纯Pluck
		snapshotQuery := h.db.Model(&models.Post{}).Where("status != ?", models.PostStatusDeleted)
		if boardIDStr != "" {
			boardID, err := strconv.Atoi(boardIDStr)
			if err == nil {
				snapshotQuery = snapshotQuery.Where("board_id = ?", boardID)
			}
		}
		if postType != "" {
			snapshotQuery = snapshotQuery.Where("post_type = ?", postType)
		}
		if sort == "all" {
			snapshotQuery = snapshotQuery.Order("(like_count*5 + reply_count*10 + view_count*0.2) / (((strftime('%s','now') - strftime('%s',created_at))/3600.0 + 2) * ((strftime('%s','now') - strftime('%s',created_at))/3600.0 + 2)) DESC")
		} else if sort == "hot" {
			snapshotQuery = snapshotQuery.Order("(view_count*1 + like_count*20 + reply_count*50) DESC")
		}
		snapshotQuery.Limit(500).Pluck("id", &allIDs)

		sessionID = fmt.Sprintf("%d", time.Now().UnixNano())
		ActiveSnapshots.Store(sessionID, Snapshot{
			PostIDs:   allIDs,
			ExpiredAt: time.Now().Add(10 * time.Minute),
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
			h.db.Model(&models.Post{}).Where("id IN ?", targetIDs).Preload("Author").Preload("Images").Preload("Images.File").Find(&rawPosts)
			
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
		// 普通查询分页
		query.Offset(offset).Limit(limit).Find(&posts)
	}

	h.fillLikes(c, posts)

	c.JSON(http.StatusOK, gin.H{
		"posts": posts,
		"total": total,
		"page":  page,
		"limit": limit,
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

"""
    
    new_lines = lines[:start_idx] + [new_getlist] + lines[end_idx:]
    with open('e:/AI/xynewui/server/internal/handlers/post.go', 'w', encoding='utf-8') as f:
        f.writelines(new_lines)
    print("GetList rewritten successfully")
else:
    print('Failed to find GetList')
