package handlers

import (
	"encoding/json"
	"fmt"
	"net/http"

	"shenliyuan/internal/models"

	"github.com/gin-gonic/gin"
	"gorm.io/gorm"
)

// EduHandler 教务处理器
type EduHandler struct {
	db *gorm.DB
}

// NewEduHandler 创建教务处理器
func NewEduHandler(db *gorm.DB) *EduHandler {
	return &EduHandler{db: db}
}

type BindEduInput struct {
	StudentID string `json:"student_id" binding:"required,len=10"`
	Password  string `json:"password" binding:"required"`
}

// BindEdu 绑定教务账号
func (h *EduHandler) BindEdu(c *gin.Context) {
	userID, _ := c.Get("user_id")

	var input BindEduInput
	if err := c.ShouldBindJSON(&input); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "参数错误: " + err.Error()})
		return
	}

	client := NewEduServiceClient()

	resp, err := client.Post("/api/edu/bind", map[string]interface{}{
		"user_id":    fmt.Sprintf("%d", userID),
		"student_id": input.StudentID,
		"password":   input.Password,
	})

	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "无法连接教务服务，请检查网络"})
		return
	}

	if resp.StatusCode() != 200 {
		c.JSON(resp.StatusCode(), gin.H{"error": ExtractError(resp)})
		return
	}

	var bindResp struct {
		Success   bool   `json:"success"`
		Message   string `json:"message"`
		StudentID string `json:"student_id"`
		Cookie    string `json:"cookie"`
		Name      string `json:"name"`
		Grade     string `json:"grade"`
		College   string `json:"college"`
		Major     string `json:"major"`
	}
	if err := json.Unmarshal(resp.Body(), &bindResp); err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "解析服务响应失败"})
		return
	}

	// 更新用户教务信息，不再存储明文密码，也不在Go端保存cookie
	err = h.db.Model(&models.User{}).Where("id = ?", userID).Updates(map[string]interface{}{
		"edu_student_id": bindResp.StudentID,
		"edu_password":   "",
		"edu_cookie":     "",
		"edu_bound":      true,
		"edu_grade":      bindResp.Grade,
		"edu_college":    bindResp.College,
		"edu_major":      bindResp.Major,
	}).Error

	if err != nil {
		// 补偿逻辑：Go更新失败，则主动去Python端解绑
		client.Delete("/api/edu/bind", map[string]string{
			"user_id": fmt.Sprintf("%d", userID),
		})
		c.JSON(http.StatusInternalServerError, gin.H{"error": "数据库更新失败，绑定已回滚"})
		return
	}

	c.JSON(http.StatusOK, gin.H{
		"message":        "绑定成功",
		"edu_student_id": bindResp.StudentID,
		"edu_grade":      bindResp.Grade,
		"edu_college":    bindResp.College,
		"edu_major":      bindResp.Major,
	})
}

// UnbindEdu 解绑教务账号
func (h *EduHandler) UnbindEdu(c *gin.Context) {
	userID, _ := c.Get("user_id")

	client := NewEduServiceClient()
	// 通知 Python 服务解绑 (补偿逻辑也复用此接口，必须幂等)
	client.Delete("/api/edu/bind", map[string]string{
		"user_id": fmt.Sprintf("%d", userID),
	})

	h.db.Model(&models.User{}).Where("id = ?", userID).Updates(map[string]interface{}{
		"edu_student_id": "",
		"edu_password":   "",
		"edu_cookie":     "",
		"edu_bound":      false,
		"edu_grade":      "",
		"edu_college":    "",
		"edu_major":      "",
	})

	c.JSON(http.StatusOK, gin.H{"message": "解绑成功"})
}

// GetEduStatus 获取教务绑定状态
func (h *EduHandler) GetEduStatus(c *gin.Context) {
	userID, _ := c.Get("user_id")

	var user models.User
	if err := h.db.First(&user, userID).Error; err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "用户不存在"})
		return
	}

	c.JSON(http.StatusOK, gin.H{
		"edu_bound":      user.EduBound,
		"edu_student_id": user.EduStudentID,
		"edu_grade":      user.EduGrade,
		"edu_college":    user.EduCollege,
		"edu_major":      user.EduMajor,
	})
}

type PreVerifyInput struct {
	StudentID string `json:"student_id" binding:"required,len=10"`
	Password  string `json:"password" binding:"required"`
}

// PreVerify 注册前验证教务账号
func (h *EduHandler) PreVerify(c *gin.Context) {
	var input PreVerifyInput
	if err := c.ShouldBindJSON(&input); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "参数错误"})
		return
	}

	var count int64
	h.db.Model(&models.User{}).Where("student_id = ?", input.StudentID).Count(&count)
	if count > 0 {
		c.JSON(http.StatusBadRequest, gin.H{"error": "该学号已注册，请直接登录", "success": false})
		return
	}

	client := NewEduServiceClient()
	resp, err := client.Post("/api/edu/pre_verify", map[string]interface{}{
		"student_id": input.StudentID,
		"password":   input.Password,
	})

	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "无法连接教务系统", "success": false})
		return
	}

	if resp.StatusCode() != 200 {
		c.JSON(http.StatusUnauthorized, gin.H{"error": ExtractError(resp), "success": false})
		return
	}

	var verifyResp struct {
		Success bool   `json:"success"`
		Message string `json:"message"`
		Name    string `json:"name"`
	}
	if err := json.Unmarshal(resp.Body(), &verifyResp); err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "解析服务响应失败", "success": false})
		return
	}

	if !verifyResp.Success {
		c.JSON(http.StatusUnauthorized, gin.H{"error": verifyResp.Message, "success": false})
		return
	}

	c.JSON(http.StatusOK, gin.H{
		"success":        true,
		"message":        "验证通过",
		"edu_student_id": input.StudentID,
		"name":           verifyResp.Name,
	})
}

type CourseInput struct {
	Year     string `json:"year" binding:"required"`
	Semester int    `json:"semester" binding:"required,oneof=3 12"`
}

// GetCourses 获取课表
func (h *EduHandler) GetCourses(c *gin.Context) {
	userID, _ := c.Get("user_id")

	var user models.User
	if err := h.db.First(&user, userID).Error; err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "用户不存在"})
		return
	}
	if !user.EduBound {
		c.JSON(http.StatusBadRequest, gin.H{"error": "请先绑定教务账号"})
		return
	}

	var input CourseInput
	if err := c.ShouldBindJSON(&input); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
		return
	}

	client := NewEduServiceClient()
	resp, err := client.Post("/api/edu/courses/fetch", map[string]interface{}{
		"user_id":  fmt.Sprintf("%d", userID),
		"year":     input.Year,
		"semester": input.Semester,
	})

	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "无法连接教务服务"})
		return
	}

	if resp.StatusCode() != 200 {
		c.JSON(resp.StatusCode(), gin.H{"error": ExtractError(resp)})
		return
	}

	c.Data(http.StatusOK, "application/json", resp.Body())
}

type SyncCourseInput struct {
	Year           string                   `json:"year" binding:"required"`
	Semester       int                      `json:"semester" binding:"required"`
	RawJSON        string                   `json:"raw_json" binding:"required"`
	Customizations []map[string]interface{} `json:"customizations"`
}

// SyncCourses 同步并解析缓存课表
func (h *EduHandler) SyncCourses(c *gin.Context) {
	userID, _ := c.Get("user_id")

	var input SyncCourseInput
	if err := c.ShouldBindJSON(&input); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
		return
	}

	client := NewEduServiceClient()
	resp, err := client.Post("/api/edu/courses/sync", map[string]interface{}{
		"user_id":        fmt.Sprintf("%d", userID),
		"year":           input.Year,
		"semester":       input.Semester,
		"raw_json":       input.RawJSON,
		"customizations": input.Customizations,
	})

	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "无法连接教务服务"})
		return
	}

	if resp.StatusCode() != 200 {
		c.JSON(resp.StatusCode(), gin.H{"error": ExtractError(resp)})
		return
	}

	c.Data(http.StatusOK, "application/json", resp.Body())
}

type GradesInput struct {
	Year     string `json:"year" binding:"required"`
	Semester int    `json:"semester" binding:"required,oneof=3 12"`
}

// GetGrades 获取成绩
func (h *EduHandler) GetGrades(c *gin.Context) {
	userID, _ := c.Get("user_id")

	var user models.User
	if err := h.db.First(&user, userID).Error; err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "用户不存在"})
		return
	}
	if !user.EduBound {
		c.JSON(http.StatusBadRequest, gin.H{"error": "请先绑定教务账号"})
		return
	}

	var input GradesInput
	if err := c.ShouldBindJSON(&input); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
		return
	}

	client := NewEduServiceClient()
	resp, err := client.Post("/api/edu/grades/", map[string]interface{}{
		"user_id":  fmt.Sprintf("%d", userID),
		"year":     input.Year,
		"semester": input.Semester,
	})

	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "无法连接教务服务"})
		return
	}

	if resp.StatusCode() != 200 {
		c.JSON(resp.StatusCode(), gin.H{"error": ExtractError(resp)})
		return
	}

	c.Data(http.StatusOK, "application/json", resp.Body())
}
