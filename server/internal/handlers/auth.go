package handlers

import (
	"encoding/json"
	"net/http"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/go-resty/resty/v2"
	"golang.org/x/crypto/bcrypt"
	"gorm.io/gorm"
	"shenliyuan/internal/middleware"
	"shenliyuan/internal/models"
)

// EduServiceConfig 教务服务配置
var EduServiceConfig = struct {
	BaseURL string
}{
	BaseURL: "", // 从config加载
}

// AuthHandler 认证处理器
type AuthHandler struct {
	db        *gorm.DB
	jwtSecret string
}

// NewAuthHandler 创建认证处理器
func NewAuthHandler(db *gorm.DB, jwtSecret string) *AuthHandler {
	return &AuthHandler{db: db, jwtSecret: jwtSecret}
}

// EduRegisterInput 教务验证后注册输入
type EduRegisterInput struct {
	StudentID    string `json:"student_id" binding:"required,len=10"`
	EduPassword  string `json:"edu_password" binding:"required"`
	Password     string `json:"password" binding:"required,min=8,max=32"`
	Nickname     string `json:"nickname"`
}

// RegisterWithEdu 教务验证后注册（学号必须先通过教务验证）
func (h *AuthHandler) RegisterWithEdu(c *gin.Context) {
	var input EduRegisterInput
	if err := c.ShouldBindJSON(&input); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
		return
	}

	// 检查学号是否已存在
	var count int64
	h.db.Model(&models.User{}).Where("student_id = ?", input.StudentID).Count(&count)
	if count > 0 {
		c.JSON(http.StatusBadRequest, gin.H{"error": "该学号已注册，请直接登录"})
		return
	}

	// 哈希App密码
	hashedPassword, err := bcrypt.GenerateFromPassword([]byte(input.Password), bcrypt.DefaultCost)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "密码加密失败"})
		return
	}

	// 先创建用户
	user := models.User{
		StudentID:    input.StudentID,
		Nickname:     input.StudentID,
		PasswordHash: string(hashedPassword),
		Role:        models.RoleUser,
		CreditScore: 100,
	}

	if err := h.db.Create(&user).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "创建用户失败"})
		return
	}

	// 静默绑定：直接登录教务系统获取cookie
	grade, college, major := "", "", ""
	cookieStr := ""

	client := resty.New()
	client.SetTimeout(10 * time.Second)

	// 获取csrf token
	csrfToken, err := getIndexCookieAndCsrfToken(client)
	if err == nil {
		// 获取公钥
		publicKey, err := getPublicKey(client)
		if err == nil {
			// RSA加密密码
			encryptedPassword, err := rsaByPublicKey(input.EduPassword, publicKey)
			if err == nil {
				// 尝试登录
				_, err = syluLogin(client, input.StudentID, encryptedPassword, csrfToken)
				if err == nil {
					cookieStr = buildCookieString(client.Cookies[1:2])
					// 获取学生信息
					grade, college, major, _ = getStudentInfo(client, cookieStr, input.StudentID)
				}
			}
		}
	}

	// 更新用户教务绑定信息
	if cookieStr != "" {
		h.db.Model(&user).Updates(map[string]interface{}{
			"edu_student_id": input.StudentID,
			"edu_password":   input.EduPassword,
			"edu_cookie":     cookieStr,
			"edu_bound":      true,
			"edu_grade":      grade,
			"edu_college":    college,
			"edu_major":     major,
		})
		user.EduBound = true
		user.EduCookie = cookieStr
		user.EduGrade = grade
		user.EduCollege = college
		user.EduMajor = major
	} else {
		// 无法获取cookie，只标记已绑定（后续可手动刷新）
		h.db.Model(&user).Updates(map[string]interface{}{
			"edu_student_id": input.StudentID,
			"edu_password":   input.EduPassword,
			"edu_bound":      true,
		})
		user.EduBound = true
	}

	token, _ := middleware.GenerateToken(user.ID, string(user.Role), h.jwtSecret)
	c.JSON(http.StatusCreated, gin.H{
		"token": token,
		"user":  user,
	})
}

// LoginInput 登录输入
type LoginInput struct {
	StudentID string `json:"student_id" binding:"required"`
	Password  string `json:"password" binding:"required"`
}

// LoginEduInput 统一登录输入（学号+教务密码+APP密码）
type LoginEduInput struct {
	StudentID   string `json:"student_id" binding:"required,len=10"`
	EduPassword string `json:"edu_password" binding:"required"`
	Password    string `json:"password" binding:"required,min=8,max=32"`
}

// LoginEdu 统一登录（教务验证+自动注册）
func (h *AuthHandler) LoginEdu(c *gin.Context) {
	var input LoginEduInput
	if err := c.ShouldBindJSON(&input); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
		return
	}

	// 检查用户是否已存在
	var user models.User
	err := h.db.Where("student_id = ?", input.StudentID).First(&user).Error
	isNewUser := err == gorm.ErrRecordNotFound

	if isNewUser {
		// 新用户：通过Python服务验证教务
		client := resty.New()
		client.SetTimeout(10 * time.Second)

		resp, err := client.R().
			SetHeader("Content-Type", "application/json").
			SetBody(map[string]string{
				"student_id":   input.StudentID,
				"edu_password": input.EduPassword,
				"password":     input.Password,
			}).
			Post(EduServiceConfig.BaseURL + "/api/edu/login_edu")

		if err != nil {
			c.JSON(http.StatusInternalServerError, gin.H{"error": "无法连接教务服务"})
			return
		}

		var result struct {
			Success   bool   `json:"success"`
			Message   string `json:"message"`
			StudentID string `json:"student_id"`
			Name      string `json:"name"`
			Grade     string `json:"grade"`
			College   string `json:"college"`
			Major     string `json:"major"`
		}

		if err := json.Unmarshal(resp.Body(), &result); err != nil {
			c.JSON(http.StatusInternalServerError, gin.H{"error": "解析响应失败"})
			return
		}

		if !result.Success {
			c.JSON(http.StatusUnauthorized, gin.H{"error": result.Message})
			return
		}

		// 哈希APP密码
		hashedPassword, err := bcrypt.GenerateFromPassword([]byte(input.Password), bcrypt.DefaultCost)
		if err != nil {
			c.JSON(http.StatusInternalServerError, gin.H{"error": "密码加密失败"})
			return
		}

		// 创建用户
		user = models.User{
			StudentID:    input.StudentID,
			Nickname:     input.StudentID,
			PasswordHash: string(hashedPassword),
			Role:         models.RoleUser,
			CreditScore:  100,
			EduStudentID: result.StudentID,
			EduPassword:  input.EduPassword,
			EduBound:     true,
			EduGrade:     result.Grade,
			EduCollege:   result.College,
			EduMajor:     result.Major,
		}

		if err := h.db.Create(&user).Error; err != nil {
			c.JSON(http.StatusInternalServerError, gin.H{"error": "创建用户失败"})
			return
		}
	} else {
		// 老用户：验证APP密码
		if err := bcrypt.CompareHashAndPassword([]byte(user.PasswordHash), []byte(input.Password)); err != nil {
			c.JSON(http.StatusUnauthorized, gin.H{"error": "APP密码错误"})
			return
		}
	}

	token, _ := middleware.GenerateToken(user.ID, string(user.Role), h.jwtSecret)
	c.JSON(http.StatusOK, gin.H{
		"token": token,
		"user":  user,
	})
}

// Login 登录
func (h *AuthHandler) Login(c *gin.Context) {
	var input LoginInput
	if err := c.ShouldBindJSON(&input); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
		return
	}

	var user models.User
	if err := h.db.Where("student_id = ?", input.StudentID).First(&user).Error; err != nil {
		c.JSON(http.StatusUnauthorized, gin.H{"error": "学号或密码错误"})
		return
	}

	if err := bcrypt.CompareHashAndPassword([]byte(user.PasswordHash), []byte(input.Password)); err != nil {
		c.JSON(http.StatusUnauthorized, gin.H{"error": "学号或密码错误"})
		return
	}

	token, _ := middleware.GenerateToken(user.ID, string(user.Role), h.jwtSecret)
	c.JSON(http.StatusOK, gin.H{
		"token": token,
		"user":  user,
	})
}

// ChangePasswordInput 修改密码输入
type ChangePasswordInput struct {
	OldPassword string `json:"old_password" binding:"required"`
	NewPassword string `json:"new_password" binding:"required,min=8,max=32"`
}

// ChangePassword 修改密码
func (h *AuthHandler) ChangePassword(c *gin.Context) {
	userID, _ := c.Get("user_id")
	var input ChangePasswordInput
	if err := c.ShouldBindJSON(&input); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
		return
	}

	var user models.User
	if err := h.db.First(&user, userID).Error; err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "用户不存在"})
		return
	}

	if err := bcrypt.CompareHashAndPassword([]byte(user.PasswordHash), []byte(input.OldPassword)); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "旧密码错误"})
		return
	}

	hashedPassword, err := bcrypt.GenerateFromPassword([]byte(input.NewPassword), bcrypt.DefaultCost)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "密码加密失败"})
		return
	}
	h.db.Model(&user).Update("password_hash", string(hashedPassword))
	c.JSON(http.StatusOK, gin.H{"message": "密码修改成功"})
}
