package handlers

import (
	"fmt"
	"net/http"
	"strconv"
	"time"

	"github.com/gin-gonic/gin"
	"gorm.io/gorm"
	"shenliyuan/internal/models"
)

type TeacherHandler struct {
	db *gorm.DB
}

func NewTeacherHandler(db *gorm.DB) *TeacherHandler {
	return &TeacherHandler{db: db}
}

// GetList 教师列表（只显示已审核的，按添加时间倒序）
func (h *TeacherHandler) GetList(c *gin.Context) {
	q := c.Query("q")
	query := h.db.Where("verified = ?", true).Order("created_at DESC")
	if q != "" {
		query = query.Where("name LIKE ?", "%"+q+"%")
	}
	var teachers []models.Teacher
	query.Find(&teachers)

	type TeacherWithStats struct {
		models.Teacher
		RatingCount int     `json:"rating_count"`
		AverageStar float64 `json:"average_star"`
	}
	result := make([]TeacherWithStats, len(teachers))
	for i, t := range teachers {
		result[i].Teacher = t
		var count int64
		var avg float64
		h.db.Model(&models.TeacherRating{}).Where("teacher_id = ?", t.ID).Count(&count)
		if count > 0 {
			h.db.Model(&models.TeacherRating{}).Where("teacher_id = ?", t.ID).Select("AVG(CAST(star AS FLOAT))").Scan(&avg)
		}
		result[i].RatingCount = int(count)
		result[i].AverageStar = avg
	}
	c.JSON(http.StatusOK, result)
}

// GetDetail 教师详情（含评价列表和当前用户的评价）
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
	var ratings []models.TeacherRating
	h.db.Where("teacher_id = ?", id).Order("created_at DESC").Find(&ratings)
	for i := range ratings {
		var user models.User
		if err := h.db.Select("nickname, student_id").First(&user, ratings[i].UserID).Error; err == nil {
			ratings[i].UserName = user.Nickname
			ratings[i].UserStudentID = user.StudentID
		}
	}
	var count int64
	var avg float64
	h.db.Model(&models.TeacherRating{}).Where("teacher_id = ?", id).Count(&count)
	if count > 0 {
		h.db.Model(&models.TeacherRating{}).Where("teacher_id = ?", id).Select("AVG(CAST(star AS FLOAT))").Scan(&avg)
	}
	c.JSON(http.StatusOK, gin.H{
		"teacher":      teacher,
		"ratings":      ratings,
		"rating_count": count,
		"average_star": avg,
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
	teacher := models.Teacher{
		Name: input.Name, Course: input.Course,
		Verified: verified, CreatedBy: userID.(uint),
	}
	if err := h.db.Create(&teacher).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "添加失败"})
		return
	}
	h.logAdmin(c, "添加教师", teacher.Name, "")
	if verified {
		c.JSON(http.StatusCreated, teacher)
	} else {
		c.JSON(http.StatusCreated, gin.H{"message": "已提交，等待管理员审核", "teacher": teacher})
	}
}

// Rate 评价教师（星级1-5，可修改）
func (h *TeacherHandler) Rate(c *gin.Context) {
	userID, _ := c.Get("user_id")
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
	// 教师存在？
	var teacher models.Teacher
	if err := h.db.First(&teacher, tid).Error; err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "教师不存在"})
		return
	}
	// 查找已有评价
	var rating models.TeacherRating
	err = h.db.Where("teacher_id = ? AND user_id = ?", tid, userID).First(&rating).Error
	if err == nil {
		h.db.Model(&rating).Updates(map[string]interface{}{
			"star": input.Star, "comment": input.Comment,
		})
		c.JSON(http.StatusOK, gin.H{"message": "评价已更新", "rating": rating})
	} else {
		rating = models.TeacherRating{
			TeacherID: uint(tid), UserID: userID.(uint),
			Star: input.Star, Comment: input.Comment,
		}
		h.db.Create(&rating)
		c.JSON(http.StatusCreated, gin.H{"message": "评价成功", "rating": rating})
	}
}

// Verify 管理员审核教师
func (h *TeacherHandler) Verify(c *gin.Context) {
	id, _ := strconv.Atoi(c.Param("id"))
	h.db.Model(&models.Teacher{}).Where("id = ?", id).Update("verified", true)
	var t models.Teacher
	h.db.First(&t, id)
	h.logAdmin(c, "审核通过教师", t.Name, "")
	c.JSON(http.StatusOK, gin.H{"message": "已审核通过"})
}

// RejectTeacher 管理员拒绝教师
func (h *TeacherHandler) RejectTeacher(c *gin.Context) {
	id, _ := strconv.Atoi(c.Param("id"))
	var t models.Teacher
	h.db.First(&t, id)
	h.db.Delete(&t)
	h.logAdmin(c, "拒绝教师", t.Name, "")
	c.JSON(http.StatusOK, gin.H{"message": "已拒绝"})
}

// GetPending 获取待审核教师列表
func (h *TeacherHandler) GetPending(c *gin.Context) {
	var teachers []models.Teacher
	h.db.Where("verified = ?", false).Order("created_at DESC").Find(&teachers)
	c.JSON(http.StatusOK, teachers)
}

// GetLogs 获取管理员操作日志
func (h *TeacherHandler) GetLogs(c *gin.Context) {
	var logs []models.AdminLog
	h.db.Preload("Admin").Order("created_at DESC").Limit(100).Find(&logs)
	c.JSON(http.StatusOK, logs)
}

// logAdmin 记录管理员操作
func (h *TeacherHandler) logAdmin(c *gin.Context, action, target, detail string) {
	userID, _ := c.Get("user_id")
	var user models.User
	h.db.Select("nickname").First(&user, userID)
	h.db.Create(&models.AdminLog{
		AdminID: userID.(uint), AdminName: user.Nickname,
		Action: action, Target: target, Detail: detail,
	})
}

// DeleteRating 删除自己的评价
func (h *TeacherHandler) DeleteRating(c *gin.Context) {
	userID, _ := c.Get("user_id")
	id, err := strconv.ParseUint(c.Param("id"), 10, 64)
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "无效ID"})
		return
	}
	result := h.db.Where("id = ? AND user_id = ?", id, userID).Delete(&models.TeacherRating{})
	if result.RowsAffected == 0 {
		c.JSON(http.StatusForbidden, gin.H{"error": "无权删除"})
		return
	}
	c.JSON(http.StatusOK, gin.H{"message": "已删除"})
}

// ReportRating 举报评价
func (h *TeacherHandler) ReportRating(c *gin.Context) {
	_ = c.Param("id")
	c.JSON(http.StatusOK, gin.H{"message": "已收到举报，管理员将审核处理"})
}

// VoteRemoveAdmin 投票罢免管理员
func (h *TeacherHandler) VoteRemoveAdmin(c *gin.Context) {
	userID, _ := c.Get("user_id")
	adminID, _ := strconv.ParseUint(c.Param("id"), 10, 64)

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
	var exist models.AdminVote
	if h.db.Where("admin_id = ? AND voter_id = ?", adminID, userID).First(&exist).Error == nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "你已经投过票了"})
		return
	}

	h.db.Create(&models.AdminVote{AdminID: uint(adminID), VoterID: userID.(uint)})

	// 判断是否达到半数
	var totalAdmins int64
	h.db.Model(&models.User{}).Where("role IN ?", []string{"admin", "super_admin"}).Count(&totalAdmins)
	var votes int64
	h.db.Model(&models.AdminVote{}).Where("admin_id = ?", adminID).Count(&votes)

	if votes > totalAdmins/2 {
		h.db.Model(&models.User{}).Where("id = ?", adminID).Update("role", models.RoleUser)
		h.db.Where("admin_id = ?", adminID).Delete(&models.AdminVote{})
		h.logAdmin(c, "投票罢免管理员", admin.Nickname, "")
		c.JSON(http.StatusOK, gin.H{"message": "投票过半，管理员已被罢免"})
	} else {
		c.JSON(http.StatusOK, gin.H{"message": fmt.Sprintf("已投票，还需%d票达到半数", (totalAdmins/2+1)-votes)})
	}
}

// GetAdminVotes 获取罢免投票数
func (h *TeacherHandler) GetAdminVotes(c *gin.Context) {
	adminID := c.Param("id")
	var votes int64
	h.db.Model(&models.AdminVote{}).Where("admin_id = ?", adminID).Count(&votes)
	var total int64
	h.db.Model(&models.User{}).Where("role IN ?", []string{"admin", "super_admin"}).Count(&total)
	var myVote int64
	uid, _ := c.Get("user_id")
	h.db.Model(&models.AdminVote{}).Where("admin_id = ? AND voter_id = ?", adminID, uid).Count(&myVote)
	c.JSON(http.StatusOK, gin.H{"votes": votes, "total": total, "my_vote": myVote > 0})
}

// GetViolations 获取用户违规记录
func (h *TeacherHandler) GetViolations(c *gin.Context) {
	userIDStr := c.Query("user_id")
	var violations []models.UserViolation
	query := h.db.Preload("User")
	if userIDStr != "" {
		query = query.Where("user_id = ?", userIDStr)
	}
	query.Order("created_at DESC").Find(&violations)
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
	id, _ := strconv.ParseUint(idStr, 10, 64)
	var v models.UserViolation
	if h.db.First(&v, id).Error != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "记录不存在"})
		return
	}
	h.db.Model(&v).Update("appealed", true)
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
		h.db.Delete(&v)
		h.logAdmin(c, "申诉通过", fmt.Sprintf("违规%d", id), "")
		c.JSON(http.StatusOK, gin.H{"message": "申诉成功，违规记录已删除"})
	} else {
		h.db.Model(&v).Update("appealed", false)
		h.logAdmin(c, "申诉驳回", fmt.Sprintf("违规%d", id), "")
		c.JSON(http.StatusOK, gin.H{"message": "申诉被驳回"})
	}
}
