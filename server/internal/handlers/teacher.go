package handlers

import (
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"strconv"
	"strings"
	"time"

	"shenliyuan/internal/models"
	"shenliyuan/internal/services"

	"github.com/gin-gonic/gin"
	"gorm.io/gorm"
	"gorm.io/gorm/clause"
)

// ensureTeacherCourseSubject 按课程名维护标准学科归属。
//
// 旧 /teachers 入口仍以自由文本课程名为主，这里只做等价名称的归属：
// 名称规范化不删除括号、后缀或数字，因此"高等数学A1"与"高等数学A2"保持不同实体。
// 并发下若已有同名学科，直接复用 canonical 行，不向调用方暴露 duplicate 错误。
func ensureTeacherCourseSubject(db *gorm.DB, courseName string, verified bool) *uint {
	normalized := models.NormalizeCourseSubjectName(courseName)
	if normalized == "" {
		return nil
	}
	var subject models.CourseSubject
	err := db.Where("normalized_name = ?", normalized).Order("verified DESC, id ASC").First(&subject).Error
	if err == nil {
		for subject.MergedIntoID != nil && *subject.MergedIntoID != 0 {
			var keeper models.CourseSubject
			if err := db.First(&keeper, *subject.MergedIntoID).Error; err == nil {
				subject = keeper
			} else {
				break
			}
		}
		if verified && !subject.Verified {
			_ = db.Model(&models.CourseSubject{}).Where("id = ?", subject.ID).Update("verified", true).Error
		}
		id := subject.ID
		return &id
	}
	if !errors.Is(err, gorm.ErrRecordNotFound) {
		return nil
	}
	// 精确名称未命中时，先按课程别名解析到 canonical subject，避免治理过的
	// 重复课程（如"高数上" → 高等数学A1）被重新创建出来。
	if resolved, rerr := resolveSubjectForPending(db, courseName); rerr == nil && resolved != nil {
		if verified && !resolved.Verified {
			_ = db.Model(&models.CourseSubject{}).Where("id = ?", resolved.ID).Update("verified", true).Error
		}
		id := resolved.ID
		return &id
	}
	candidate := models.CourseSubject{
		Name:            strings.TrimSpace(courseName),
		NormalizedName:  normalized,
		Verified:        verified,
		CanonicalSource: models.TeacherSourceUser,
	}
	if err := db.Clauses(clause.OnConflict{DoNothing: true}).Create(&candidate).Error; err != nil {
		return nil
	}
	if candidate.ID == 0 {
		if err := db.Where("normalized_name = ?", normalized).Order("verified DESC, id ASC").First(&subject).Error; err != nil {
			return nil
		}
		id := subject.ID
		return &id
	}
	id := candidate.ID
	return &id
}

// detachCourseEvaluationSubmission 删除公开评价时解绑提交记录，
// 避免提交记录仍标称 published 却指向一条已删除的评价。
// 记录转入 needs_edit 等待用户重新提交，不直接进入管理员待审核队列。
func detachCourseEvaluationSubmission(db *gorm.DB, ratingID uint) {
	if ratingID == 0 {
		return
	}
	_ = db.Model(&models.CourseEvaluationSubmission{}).
		Where("teacher_rating_id = ?", ratingID).
		Updates(map[string]interface{}{
			"teacher_rating_id": nil,
			"status":            models.CourseEvaluationStatusNeedsEdit,
		}).Error
}

type TeacherHandler struct {
	db *gorm.DB
}

func NewTeacherHandler(db *gorm.DB) *TeacherHandler {
	return &TeacherHandler{db: db}
}

// GetList 教师列表（只显示已审核且未合并的，按添加时间倒序）
func (h *TeacherHandler) GetList(c *gin.Context) {
	q := c.Query("q")

	type TeacherWithStats struct {
		models.Teacher
		RatingCount int     `json:"rating_count"`
		AverageStar float64 `json:"average_star"`
	}
	var result []TeacherWithStats

	query := h.db.Table("teachers").
		Select("teachers.*, COUNT(teacher_ratings.id) as rating_count, COALESCE(AVG(CAST(teacher_ratings.star AS FLOAT)), 0) as average_star").
		Joins("LEFT JOIN teacher_ratings ON teacher_ratings.teacher_id = teachers.id AND teacher_ratings.status = 'normal' AND teacher_ratings.deleted_at IS NULL").
		Where("teachers.verified = ?", true).
		Where("teachers.merged_into_id IS NULL").
		Group("teachers.id").
		Order("teachers.created_at DESC")

	if q != "" {
		query = query.Where("teachers.name LIKE ?", "%"+q+"%")
	}

	if err := query.Find(&result).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "获取教师列表失败"})
		return
	}

	c.JSON(http.StatusOK, result)
}

// GetDetail 教师详情（含评价列表和当前用户的评价）。
// 已合并的教师返回 merged 标记与目标 ID，客户端据此跳转到保留教师。
func (h *TeacherHandler) GetDetail(c *gin.Context) {
	id, err := strconv.ParseUint(c.Param("id"), 10, 64)
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "无效ID"})
		return
	}
	var teacher models.Teacher
	if err := h.db.First(&teacher, id).Error; err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "教师不存在"})
		return
	}
	if teacher.MergedIntoID != nil {
		keeperName := ""
		var keeper models.Teacher
		if err := h.db.Select("id", "name").First(&keeper, *teacher.MergedIntoID).Error; err == nil {
			keeperName = keeper.Name
		}
		c.JSON(http.StatusOK, gin.H{
			"teacher": gin.H{
				"id":                teacher.ID,
				"name":              teacher.Name,
				"course":            teacher.Course,
				"course_subject_id": teacher.CourseSubjectID,
				"rating_count":      teacher.RatingCount,
				"average_star":      teacher.AverageStar,
				"created_at":        teacher.CreatedAt,
				"verified":          teacher.Verified,
				"canonical_source":  teacher.CanonicalSource,
				"is_merged":          true,
				"merged":            true,
				"merged_into_id":    teacher.MergedIntoID,
				"merged_into_name":  keeperName,
			},
			"merged":           true,
			"merged_into_id":   teacher.MergedIntoID,
			"merged_into_name": keeperName,
			"ratings":          []interface{}{},
		})
		return
	}
	sortMode := c.Query("review_sort")
	var ratings []models.TeacherRating
	query := h.db.Where("teacher_id = ? AND status = 'normal' AND deleted_at IS NULL", id).Preload("User")

	if sortMode == "best" {
		query = query.Order("(helpful_count - unhelpful_count * 2) DESC, CASE WHEN TRIM(comment) <> '' THEN 1 ELSE 0 END DESC, helpful_count DESC, created_at DESC")
	} else {
		query = query.Order("created_at DESC")
	}

	if err := query.Find(&ratings).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "获取评价列表失败"})
		return
	}
	var ratingDTOs []map[string]interface{}
	for _, r := range ratings {
		userName := ""
		userAvatar := ""
		if r.User != nil {
			userName = r.User.Nickname
			userAvatar = r.User.Avatar
		}

		isOwn := false
		if userID, exists := c.Get("user_id"); exists {
			isOwn = r.UserID == userID.(uint)
		}

		ratingDTOs = append(ratingDTOs, map[string]interface{}{
			"id":              r.ID,
			"teacher_id":      r.TeacherID,
			"user_id":         r.UserID,
			"star":            r.Star,
			"comment":         r.Comment,
			"user_name":       userName,
			"user_avatar":     userAvatar,
			"created_at":      r.CreatedAt,
			"updated_at":      r.UpdatedAt,
			"status":          r.Status,
			"is_own":          isOwn,
			"helpful_count":   r.HelpfulCount,
			"unhelpful_count": r.UnhelpfulCount,
			"user_vote":       nil,
		})
	}

	var count int64
	var avg float64
	h.db.Model(&models.TeacherRating{}).Where("teacher_id = ? AND status = 'normal' AND deleted_at IS NULL", id).Count(&count)
	if count > 0 {
		h.db.Model(&models.TeacherRating{}).Where("teacher_id = ? AND status = 'normal' AND deleted_at IS NULL", id).Select("AVG(CAST(star AS FLOAT))").Scan(&avg)
	}

	var myRating *models.TeacherRating
	if userID, exists := c.Get("user_id"); exists {
		var mr models.TeacherRating
		if err := h.db.Where("teacher_id = ? AND user_id = ? AND deleted_at IS NULL", id, userID.(uint)).First(&mr).Error; err == nil {
			myRating = &mr
		}
	}

	c.JSON(http.StatusOK, gin.H{
		"teacher":      teacher,
		"ratings":      ratingDTOs,
		"rating_count": count,
		"average_star": avg,
		"my_rating":    myRating,
	})
}

// Create 添加教师（需管理员审核）
func (h *TeacherHandler) Create(c *gin.Context) {
	userID, _ := c.Get("user_id")
	role, _ := c.Get("role")
	var input struct {
		Name   string `json:"name" binding:"required"`
		Course string `json:"course" binding:"required"`
	}
	if err := c.ShouldBindJSON(&input); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
		return
	}
	// 管理员添加自动通过
	verified := role == "admin" || role == "super_admin"
	source := models.TeacherSourceUser
	if verified {
		source = models.TeacherSourceAdmin
	}
	teacher := models.Teacher{
		Name: input.Name, Course: input.Course,
		Verified: verified, CreatedBy: userID.(uint),
		NameNormalized:  models.NormalizeTeacherName(input.Name),
		CanonicalSource: source,
	}
	// 旧入口继续以自由文本课程名为主，同时维护标准学科归属。
	if subjectID := ensureTeacherCourseSubject(h.db, input.Course, verified); subjectID != nil {
		teacher.CourseSubjectID = subjectID
	}

	// 检查是否与同学科下既有别名冲突，避免实名撞别名导致歧义
	if teacher.CourseSubjectID != nil && *teacher.CourseSubjectID != 0 {
		var existingAlias models.TeacherAlias
		if err := h.db.Where("course_subject_id = ? AND normalized_alias = ?", *teacher.CourseSubjectID, teacher.NameNormalized).First(&existingAlias).Error; err == nil {
			c.JSON(http.StatusConflict, gin.H{"error": "该教师姓名已作为别名存在，请直接选择对应教师或联系管理员"})
			return
		}
	}

	if err := h.db.Create(&teacher).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "添加失败"})
		return
	}
	if verified {
		h.logAdmin(c, "添加教师", teacher.Name, "")
		c.JSON(http.StatusCreated, teacher)
	} else {
		c.JSON(http.StatusCreated, gin.H{"message": "已提交，等待管理员审核", "teacher": teacher})
	}
}

// Rate 兼容旧教师评分入口，但实际写入统一进入课程评价状态机。
func (h *TeacherHandler) Rate(c *gin.Context) {
	userID := c.GetUint("user_id")
	if userID == 0 {
		c.JSON(http.StatusForbidden, gin.H{"error": "请先登录"})
		return
	}
	tid, err := strconv.ParseUint(c.Param("id"), 10, 64)
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "无效ID"})
		return
	}
	var input struct {
		Star    int    `json:"star" binding:"required,min=1,max=5"`
		Comment string `json:"comment" binding:"max=500"`
	}
	if err := c.ShouldBindJSON(&input); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
		return
	}

	view, err := services.NewCourseEvaluationService(h.db).
		RateVerifiedTeacher(userID, uint(tid), input.Star, input.Comment)
	if err != nil {
		var businessErr *services.CourseEvaluationError
		if errors.As(err, &businessErr) {
			response := gin.H{
				"error": businessErr.Message,
				"code":  businessErr.Code,
			}
			for key, value := range businessErr.Details {
				response[key] = value
			}
			c.JSON(services.CourseEvaluationHTTPStatus(businessErr.Code), response)
			return
		}
		c.JSON(http.StatusInternalServerError, gin.H{"error": "课程评价服务异常，请稍后重试"})
		return
	}
	message := "评价成功"
	if view.Status != models.CourseEvaluationStatusPublished {
		message = "评价已提交，等待审核"
	}
	c.JSON(http.StatusOK, gin.H{"message": message, "submission": view})
}

// Verify 管理员审核教师。
// 审核前先做冲突收敛：若同学科已有同名活动教师（或别名已指向某教师），
// 待审行并入该教师并登记别名，避免唯一索引竞争和重复实体。
func (h *TeacherHandler) Verify(c *gin.Context) {
	id, _ := strconv.Atoi(c.Param("id"))
	var t models.Teacher
	if err := h.db.First(&t, id).Error; err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "教师不存在"})
		return
	}
	if t.MergedIntoID != nil {
		c.JSON(http.StatusConflict, gin.H{"error": "该教师已被合并，请刷新待办列表"})
		return
	}

	// 审核通过时补齐标准学科字段：教师名规范化、学科归属与学科审核状态。
	updates := map[string]interface{}{}
	if strings.TrimSpace(t.NameNormalized) == "" {
		updates["name_normalized"] = models.NormalizeTeacherName(t.Name)
	}
	if t.CourseSubjectID == nil || *t.CourseSubjectID == 0 {
		if subjectID := ensureTeacherCourseSubject(h.db, t.Course, true); subjectID != nil {
			updates["course_subject_id"] = *subjectID
		}
	} else {
		// 教师已审核，其所属学科必须同为已审核，否则学科榜读不到该教师。
		_ = h.db.Model(&models.CourseSubject{}).Where("id = ?", *t.CourseSubjectID).
			Update("verified", true).Error
	}
	if len(updates) > 0 {
		_ = h.db.Model(&models.Teacher{}).Where("id = ?", id).Updates(updates).Error
	}
	_ = h.db.First(&t, id).Error

	// 冲突收敛：同学科下已有同名活动教师，或别名已指向某教师 → 并入而非重复创建。
	if t.CourseSubjectID != nil {
		normalized := t.NameNormalized
		if normalized == "" {
			normalized = models.NormalizeTeacherName(t.Name)
		}
		var owner models.Teacher
		err := h.db.Where("course_subject_id = ? AND name_normalized = ? AND merged_into_id IS NULL AND id <> ?",
			*t.CourseSubjectID, normalized, t.ID).Order("verified DESC, id ASC").First(&owner).Error
		if errors.Is(err, gorm.ErrRecordNotFound) {
			var alias models.TeacherAlias
			if err := h.db.Where("course_subject_id = ? AND normalized_alias = ?", *t.CourseSubjectID, normalized).
				First(&alias).Error; err == nil {
				if err := h.db.Where("id = ? AND merged_into_id IS NULL", alias.TeacherID).First(&owner).Error; err != nil {
					owner = models.Teacher{}
				}
			}
		}
		if owner.ID != 0 {
			// 并入已有教师：原名登记为别名，待审行标记 merged。
			governanceService := services.NewTeacherGovernanceService(h.db)
			keeperName, err := governanceService.MergePendingTeacherInto(c.GetUint("user_id"), t.ID, owner.ID, true)
			if err != nil {
				c.JSON(http.StatusInternalServerError, gin.H{"error": "并入已有教师失败: " + err.Error()})
				return
			}
			h.logAdmin(c, "审核通过教师（并入已有）", t.Name, "并入 "+keeperName)
			c.JSON(http.StatusOK, gin.H{"message": "已并入已有教师 " + keeperName, "merged_into_id": owner.ID})
			return
		}
	}

	if err := h.db.Model(&models.Teacher{}).Where("id = ?", id).Updates(map[string]interface{}{
		"verified":         true,
		"canonical_source": models.TeacherSourceAdmin,
	}).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "数据库操作失败"})
		return
	}
	h.logAdmin(c, "审核通过教师", t.Name, "")
	c.JSON(http.StatusOK, gin.H{"message": "已审核通过"})
}

// MergeInto 管理员把一条待审教师并入已有教师（审核卡片"合并到已有教师"）。
func (h *TeacherHandler) MergeInto(c *gin.Context) {
	id, _ := strconv.Atoi(c.Param("id"))
	var body struct {
		KeeperID       uint `json:"keeper_id"`
		RegisterAlias  *bool `json:"register_alias"`
	}
	if err := c.ShouldBindJSON(&body); err != nil || body.KeeperID == 0 {
		c.JSON(http.StatusBadRequest, gin.H{"error": "缺少合并目标"})
		return
	}
	var pending models.Teacher
	if err := h.db.First(&pending, id).Error; err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "教师不存在"})
		return
	}
	if pending.MergedIntoID != nil {
		c.JSON(http.StatusConflict, gin.H{"error": "该教师已被合并，请刷新待办列表"})
		return
	}
	governanceService := services.NewTeacherGovernanceService(h.db)
	keeperName, err := governanceService.MergePendingTeacherInto(c.GetUint("user_id"), uint(id), body.KeeperID, body.RegisterAlias == nil || *body.RegisterAlias)
	if err != nil {
		var businessErr *services.TeacherGovernanceError
		if errors.As(err, &businessErr) {
			response := gin.H{"error": businessErr.Message, "code": businessErr.Code}
			for key, value := range businessErr.Details {
				response[key] = value
			}
			c.JSON(services.TeacherGovernanceHTTPStatus(businessErr.Code), response)
			return
		}
		c.JSON(http.StatusInternalServerError, gin.H{"error": "合并失败"})
		return
	}
	h.logAdmin(c, "待审教师并入已有教师", pending.Name, "并入 "+keeperName)
	c.JSON(http.StatusOK, gin.H{"message": "已并入教师 " + keeperName, "merged_into_id": body.KeeperID})
}

// RejectTeacher 管理员拒绝教师
func (h *TeacherHandler) RejectTeacher(c *gin.Context) {
	id, _ := strconv.Atoi(c.Param("id"))
	var t models.Teacher
	if err := h.db.First(&t, id).Error; err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "教师不存在"})
		return
	}
	if err := h.db.Delete(&t).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "数据库操作失败"})
		return
	}
	h.logAdmin(c, "拒绝教师", t.Name, "")
	c.JSON(http.StatusOK, gin.H{"message": "已拒绝"})
}

// GetPending 获取待审核教师列表。
// 每条待审教师附带 matched_existing_teacher（按同学科同名 / 课程别名归并 / 教师别名匹配），
// 供审核卡片展示"发现已有疑似教师"并提供合并入口。
func (h *TeacherHandler) GetPending(c *gin.Context) {
	var teachers []models.Teacher
	if err := h.db.Where("verified = ? AND merged_into_id IS NULL", false).Order("created_at DESC").Find(&teachers).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "获取待审核教师失败"})
		return
	}

	type pendingTeacherView struct {
		models.Teacher
		MatchedExistingTeacher *matchedExistingTeacher `json:"matched_existing_teacher,omitempty"`
	}
	result := make([]pendingTeacherView, 0, len(teachers))
	for _, teacher := range teachers {
		view := pendingTeacherView{Teacher: teacher}
		view.MatchedExistingTeacher = h.matchExistingTeacher(&teacher)
		result = append(result, view)
	}
	c.JSON(http.StatusOK, result)
}

type matchedExistingTeacher struct {
	ID          uint   `json:"id"`
	Name        string `json:"name"`
	Course      string `json:"course"`
	RatingCount int    `json:"rating_count"`
}

// matchExistingTeacher 为待审教师查找同学科的已有活动教师。
// 匹配顺序：同学科同名 → 课程别名归并后的学科同名 → 教师别名。
func (h *TeacherHandler) matchExistingTeacher(pending *models.Teacher) *matchedExistingTeacher {
	normalized := pending.NameNormalized
	if normalized == "" {
		normalized = models.NormalizeTeacherName(pending.Name)
	}
	if normalized == "" {
		return nil
	}

	subjectIDs := []uint{}
	if pending.CourseSubjectID != nil && *pending.CourseSubjectID != 0 {
		subjectIDs = append(subjectIDs, *pending.CourseSubjectID)
		// 课程别名归并：待审课程名命中的别名目标学科也算同源。
		if subject, err := resolveSubjectForPending(h.db, pending.Course); err == nil && subject != nil && subject.ID != *pending.CourseSubjectID {
			subjectIDs = append(subjectIDs, subject.ID)
		}
	} else if subject, err := resolveSubjectForPending(h.db, pending.Course); err == nil && subject != nil {
		subjectIDs = append(subjectIDs, subject.ID)
	}

	for _, subjectID := range subjectIDs {
		var owner models.Teacher
		err := h.db.Where("course_subject_id = ? AND name_normalized = ? AND verified = ? AND merged_into_id IS NULL AND id <> ?",
			subjectID, normalized, true, pending.ID).Order("id ASC").First(&owner).Error
		if err == nil {
			return buildMatchedTeacher(h.db, owner)
		}
		var alias models.TeacherAlias
		if err := h.db.Where("course_subject_id = ? AND normalized_alias = ?", subjectID, normalized).
			Order("id ASC").First(&alias).Error; err == nil {
			if err := h.db.Where("id = ? AND merged_into_id IS NULL AND id <> ?", alias.TeacherID, pending.ID).
				First(&owner).Error; err == nil {
				return buildMatchedTeacher(h.db, owner)
			}
		}
	}
	return nil
}

// resolveSubjectForPending 按课程名解析标准学科（精确 → 别名）。
func resolveSubjectForPending(db *gorm.DB, courseName string) (*models.CourseSubject, error) {
	normalized := models.NormalizeCourseSubjectName(courseName)
	if normalized == "" {
		return nil, gorm.ErrRecordNotFound
	}
	var subject models.CourseSubject
	if err := db.Where("normalized_name = ?", normalized).Order("verified DESC, id ASC").First(&subject).Error; err == nil {
		for subject.MergedIntoID != nil && *subject.MergedIntoID != 0 {
			var keeper models.CourseSubject
			if err := db.First(&keeper, *subject.MergedIntoID).Error; err == nil {
				subject = keeper
			} else {
				break
			}
		}
		return &subject, nil
	}
	var alias models.CourseSubjectAlias
	if err := db.Where("normalized_alias = ?", normalized).Order("id ASC").First(&alias).Error; err == nil {
		if err := db.First(&subject, alias.CourseSubjectID).Error; err == nil {
			for subject.MergedIntoID != nil && *subject.MergedIntoID != 0 {
				var keeper models.CourseSubject
				if err := db.First(&keeper, *subject.MergedIntoID).Error; err == nil {
					subject = keeper
				} else {
					break
				}
			}
			return &subject, nil
		}
	}
	return nil, gorm.ErrRecordNotFound
}

func buildMatchedTeacher(db *gorm.DB, owner models.Teacher) *matchedExistingTeacher {
	var count int64
	db.Model(&models.TeacherRating{}).
		Where("teacher_id = ? AND deleted_at IS NULL AND status = ?", owner.ID, "normal").
		Count(&count)
	return &matchedExistingTeacher{
		ID:          owner.ID,
		Name:        owner.Name,
		Course:      owner.Course,
		RatingCount: int(count),
	}
}

// GetLogs 获取管理员操作日志
func (h *TeacherHandler) GetLogs(c *gin.Context) {
	var logs []models.AdminLog
	if err := h.db.Preload("Admin").Order("created_at DESC").Limit(100).Find(&logs).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "获取管理日志失败"})
		return
	}
	c.JSON(http.StatusOK, logs)
}

// logAdmin 记录管理员操作
func (h *TeacherHandler) logAdmin(c *gin.Context, action, target, detail string) {
	userID, _ := c.Get("user_id")
	var user models.User
	h.db.Select("nickname").First(&user, userID)
	if err := h.db.Create(&models.AdminLog{
		AdminID: userID.(uint), AdminName: user.Nickname,
		Action: action, Target: target, Detail: detail,
	}).Error; err != nil {
		log.Printf("[DB_WARN] Failed to write admin log: %v", err)
	}
	// 管理员操作经验+1
	if err := h.db.Model(&models.User{}).Where("id = ?", userID).UpdateColumn("admin_exp", gorm.Expr("COALESCE(admin_exp, 0) + 1")).Error; err != nil {
		log.Printf("[DB_WARN] Failed to update admin_exp: %v", err)
	}
}

// DeleteRating 删除自己的评价
func (h *TeacherHandler) DeleteRating(c *gin.Context) {
	userID, _ := c.Get("user_id")
	id, err := strconv.ParseUint(c.Param("id"), 10, 64)
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "无效ID"})
		return
	}
	// 删除前先解绑关联的课程评价提交记录，避免提交记录指向已删除的评价。
	detachCourseEvaluationSubmission(h.db, uint(id))
	result := h.db.Where("id = ? AND user_id = ?", id, userID).Delete(&models.TeacherRating{})
	if result.RowsAffected == 0 {
		c.JSON(http.StatusForbidden, gin.H{"error": "无权删除"})
		return
	}
	c.JSON(http.StatusOK, gin.H{"message": "已删除"})
}

// VoteRating 给评价投票 (有用/没帮助)
func (h *TeacherHandler) VoteRating(c *gin.Context) {
	userID, _ := c.Get("user_id")
	ratingID, err := strconv.ParseUint(c.Param("id"), 10, 64)
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "无效的评价ID"})
		return
	}
	var input struct {
		Vote string `json:"vote" binding:"required"` // up, down, none
	}
	if err := c.ShouldBindJSON(&input); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
		return
	}

	result, err := services.ToggleRatingVote(h.db, "teacher", uint(ratingID), userID.(uint), input.Vote)
	if err != nil {
		if err.Error() == "不能给自己的评价投票" || err.Error() == "无法对该状态的评价进行投票" || err.Error() == "评价不存在或已删除" {
			c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
		} else {
			c.JSON(http.StatusInternalServerError, gin.H{"error": "投票失败"})
		}
		return
	}

	c.JSON(http.StatusOK, gin.H{
		"rating_id":       ratingID,
		"helpful_count":   result.HelpfulCount,
		"unhelpful_count": result.UnhelpfulCount,
		"my_vote":         result.MyVote,
	})
}

// ReportRating 举报评价
func (h *TeacherHandler) ReportRating(c *gin.Context) {
	ratingID, err := strconv.ParseUint(c.Param("id"), 10, 64)
	if err != nil || ratingID == 0 {
		c.JSON(http.StatusBadRequest, gin.H{"code": "invalid_rating_id", "error": "无效的评价ID"})
		return
	}
	var input struct {
		ReasonCode string `json:"reason_code"`
		Reason     string `json:"reason"`
	}
	if err := c.ShouldBindJSON(&input); err != nil && !errors.Is(err, io.EOF) {
		c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
		return
	}
	if strings.TrimSpace(input.Reason) == "" {
		input.Reason = "评价举报"
	}
	report, err := createReport(h.db, c.GetUint("user_id"), CreateReportInput{
		TargetType: "teacher_rating",
		TargetID:   uint(ratingID),
		ReasonCode: input.ReasonCode,
		Reason:     input.Reason,
	})
	if err != nil {
		writeReportCreateError(c, err)
		return
	}
	c.JSON(http.StatusCreated, report)
}

// VoteRemoveAdmin 投票罢免管理员
func (h *TeacherHandler) VoteRemoveAdmin(c *gin.Context) {
	userID, _ := c.Get("user_id")
	adminID, _ := strconv.ParseUint(c.Param("id"), 10, 64)
	var input struct {
		Reason string `json:"reason" binding:"required"`
	}
	if err := c.ShouldBindJSON(&input); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "请填写申请理由"})
		return
	}
	input.Reason = strings.TrimSpace(input.Reason)
	if input.Reason == "" {
		c.JSON(http.StatusBadRequest, gin.H{"error": "请填写申请理由"})
		return
	}

	// 只能投票罢免普通管理员
	var admin models.User
	if h.db.First(&admin, adminID).Error != nil || admin.Role != models.RoleAdmin {
		c.JSON(http.StatusBadRequest, gin.H{"error": "目标不是普通管理员"})
		return
	}

	// 不能自己投自己
	if uint64(userID.(uint)) == adminID {
		c.JSON(http.StatusBadRequest, gin.H{"error": "不能投自己"})
		return
	}

	// 检查是否已投票
	var exist models.AdminRemovalVote
	if h.db.Where("target_admin_id = ? AND voter_id = ?", adminID, userID).First(&exist).Error == nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "你已经投过票了"})
		return
	}

	if err := h.db.Create(&models.AdminRemovalVote{TargetAdminID: uint(adminID), VoterID: userID.(uint), Reason: input.Reason}).Error; err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "你已经投过票了"})
		return
	}

	// 判断是否超过可投票管理员半数，目标管理员本人不计入可投票人数。
	var totalAdmins int64
	h.db.Model(&models.User{}).Where("role IN ? AND id <> ?", []string{"admin", "super_admin"}, adminID).Count(&totalAdmins)
	var votes int64
	h.db.Model(&models.AdminRemovalVote{}).Where("target_admin_id = ?", adminID).Count(&votes)

	if votes > totalAdmins/2 {
		if err := services.UpdateUserRoleAndInvalidateToken(h.db, uint(adminID), models.RoleUser); err != nil {
			c.JSON(http.StatusInternalServerError, gin.H{"error": "数据库操作失败"})
			return
		}
		h.db.Where("target_admin_id = ?", adminID).Delete(&models.AdminRemovalVote{})
		h.logAdmin(c, "投票罢免管理员", admin.Nickname, input.Reason)
		c.JSON(http.StatusOK, gin.H{"message": "投票过半，管理员已被罢免"})
	} else {
		c.JSON(http.StatusOK, gin.H{"message": fmt.Sprintf("已投票，还需%d票达到半数", (totalAdmins/2+1)-votes)})
	}
}

// GetAdminVotes 获取罢免投票数
func (h *TeacherHandler) GetAdminVotes(c *gin.Context) {
	adminID := c.Param("id")
	var votes int64
	h.db.Model(&models.AdminRemovalVote{}).Where("target_admin_id = ?", adminID).Count(&votes)
	var total int64
	h.db.Model(&models.User{}).Where("role IN ? AND id <> ?", []string{"admin", "super_admin"}, adminID).Count(&total)
	var myVote int64
	uid, _ := c.Get("user_id")
	h.db.Model(&models.AdminRemovalVote{}).Where("target_admin_id = ? AND voter_id = ?", adminID, uid).Count(&myVote)
	c.JSON(http.StatusOK, gin.H{"votes": votes, "total": total, "required_votes": total/2 + 1, "my_vote": myVote > 0})
}

// GetRemovalRequests 获取管理员罢免待办
func (h *TeacherHandler) GetRemovalRequests(c *gin.Context) {
	uid, _ := c.Get("user_id")

	type targetRow struct {
		TargetAdminID uint
	}
	var rows []targetRow
	if err := h.db.Model(&models.AdminRemovalVote{}).
		Select("target_admin_id").
		Group("target_admin_id").
		Scan(&rows).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "获取罢免待办失败"})
		return
	}

	result := make([]gin.H, 0, len(rows))
	for _, row := range rows {
		var admin models.User
		if err := h.db.Select("id, nickname, student_id, role").First(&admin, row.TargetAdminID).Error; err != nil || admin.Role != models.RoleAdmin {
			continue
		}

		var votes []models.AdminRemovalVote
		if err := h.db.Where("target_admin_id = ?", row.TargetAdminID).Preload("Voter").Order("created_at ASC").Find(&votes).Error; err != nil {
			log.Printf("[DB_ERROR] RemoveAdmin Find votes failed: %v", err)
			continue
		}
		if len(votes) == 0 {
			continue
		}
		var myVote int64
		h.db.Model(&models.AdminRemovalVote{}).Where("target_admin_id = ? AND voter_id = ?", row.TargetAdminID, uid).Count(&myVote)
		var total int64
		h.db.Model(&models.User{}).Where("role IN ? AND id <> ?", []string{"admin", "super_admin"}, row.TargetAdminID).Count(&total)

		initiator := gin.H{}
		if votes[0].Voter.ID != 0 {
			initiator = gin.H{
				"id":         votes[0].Voter.ID,
				"nickname":   votes[0].Voter.Nickname,
				"student_id": votes[0].Voter.StudentID,
			}
		}

		result = append(result, gin.H{
			"admin":          admin,
			"reason":         votes[0].Reason,
			"initiator":      initiator,
			"votes":          len(votes),
			"total":          total,
			"required_votes": total/2 + 1,
			"my_vote":        myVote > 0,
			"can_vote":       uid.(uint) != row.TargetAdminID && myVote == 0,
			"created_at":     votes[0].CreatedAt,
		})
	}
	c.JSON(http.StatusOK, result)
}

// GetViolations 获取用户违规记录
func (h *TeacherHandler) GetViolations(c *gin.Context) {
	userID := c.GetUint("user_id")
	var violations []models.UserViolation
	if err := h.db.Where("user_id = ?", userID).
		Order("created_at DESC").Find(&violations).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "获取违规记录失败"})
		return
	}
	c.JSON(http.StatusOK, violations)
}

// GetAdminViolations 获取管理员违规记录列表。管理员能力使用独立路由，
// 避免普通用户接口通过 user_id 参数扩大读取范围。
func (h *TeacherHandler) GetAdminViolations(c *gin.Context) {
	query := h.db.Model(&models.UserViolation{}).Preload("User")
	if userIDStr := strings.TrimSpace(c.Query("user_id")); userIDStr != "" {
		userID, err := strconv.ParseUint(userIDStr, 10, 64)
		if err != nil || userID == 0 {
			c.JSON(http.StatusBadRequest, gin.H{"error": "无效的用户ID"})
			return
		}
		query = query.Where("user_id = ?", userID)
	}
	var violations []models.UserViolation
	if err := query.Order("created_at DESC").Find(&violations).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "获取违规记录失败"})
		return
	}
	c.JSON(http.StatusOK, violations)
}

// AddViolation 添加违规记录 + 禁言
func (h *TeacherHandler) AddViolation(c *gin.Context) {
	var input struct {
		UserID  uint   `json:"user_id" binding:"required"`
		BoardID uint   `json:"board_id" binding:"required"`
		Reason  string `json:"reason" binding:"required"`
		Action  string `json:"action" binding:"required"`
	}
	if err := c.ShouldBindJSON(&input); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
		return
	}
	var count int64
	h.db.Model(&models.UserViolation{}).Where("user_id = ? AND board_id = ?", input.UserID, input.BoardID).Count(&count)
	violationCount := int(count) + 1
	v := models.UserViolation{
		UserID: input.UserID, BoardID: input.BoardID,
		Reason: input.Reason, Action: input.Action, Count: violationCount,
	}
	switch {
	case violationCount >= 3:
	case violationCount == 2:
		t := time.Now().AddDate(0, 1, 0)
		v.MutedUntil = &t
	case violationCount == 1:
		t := time.Now().AddDate(0, 0, 7)
		v.MutedUntil = &t
	}
	if err := h.db.Create(&v).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "记录失败"})
		return
	}
	h.logAdmin(c, "添加违规", fmt.Sprintf("用户%d %s", input.UserID, input.Reason), "")
	c.JSON(http.StatusCreated, v)
}

// AppealViolation 申诉违规
func (h *TeacherHandler) AppealViolation(c *gin.Context) {
	idStr := c.Param("id")
	id, err := strconv.ParseUint(idStr, 10, 64)
	if err != nil || id == 0 {
		c.JSON(http.StatusNotFound, gin.H{"code": "violation_not_found", "error": "记录不存在"})
		return
	}
	userID := c.GetUint("user_id")
	var v models.UserViolation
	if err := h.db.Where("id = ? AND user_id = ?", id, userID).First(&v).Error; err != nil {
		// 对不存在和不属于当前用户的记录统一返回 404，避免枚举记录归属。
		c.JSON(http.StatusNotFound, gin.H{"code": "violation_not_found", "error": "记录不存在"})
		return
	}
	if v.Appealed {
		c.JSON(http.StatusConflict, gin.H{"code": "violation_already_appealed", "error": "该违规记录已提交申诉"})
		return
	}
	result := h.db.Model(&models.UserViolation{}).
		Where("id = ? AND user_id = ? AND appealed = ?", id, userID, false).
		Update("appealed", true)
	if result.Error != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "数据库操作失败"})
		return
	}
	if result.RowsAffected != 1 {
		c.JSON(http.StatusConflict, gin.H{"code": "violation_already_appealed", "error": "该违规记录已提交申诉"})
		return
	}
	c.JSON(http.StatusOK, gin.H{"message": "申诉已提交"})
}

// HandleAppeal 管理员处理申诉
func (h *TeacherHandler) HandleAppeal(c *gin.Context) {
	idStr := c.Param("id")
	id, _ := strconv.ParseUint(idStr, 10, 64)
	var input struct {
		Approved bool   `json:"approved"`
		Reason   string `json:"reason"`
	}
	c.ShouldBindJSON(&input)
	var v models.UserViolation
	if h.db.First(&v, id).Error != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "记录不存在"})
		return
	}
	if input.Approved {
		if err := h.db.Delete(&v).Error; err != nil {
			c.JSON(http.StatusInternalServerError, gin.H{"error": "数据库操作失败"})
			return
		}
		h.logAdmin(c, "申诉通过", fmt.Sprintf("违规%d", id), "")
		c.JSON(http.StatusOK, gin.H{"message": "申诉成功，违规记录已删除"})
	} else {
		if err := h.db.Model(&v).Update("appealed", false).Error; err != nil {
			c.JSON(http.StatusInternalServerError, gin.H{"error": "数据库操作失败"})
			return
		}
		h.logAdmin(c, "申诉驳回", fmt.Sprintf("违规%d", id), "")
		c.JSON(http.StatusOK, gin.H{"message": "申诉被驳回"})
	}
}
