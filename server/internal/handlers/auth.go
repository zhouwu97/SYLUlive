package handlers

import (
	"crypto/rand"
	"crypto/rsa"
	"encoding/base64"
	"encoding/json"
	"errors"
	"math/big"
	"net/http"
	"net/url"
	"regexp"
	"strconv"
	"strings"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/go-resty/resty/v2"
	"golang.org/x/crypto/bcrypt"
	"gorm.io/gorm"
	"shenliyuan/internal/middleware"
	"shenliyuan/internal/models"
)

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
	EduPassword   string `json:"edu_password" binding:"required"`
	Password      string `json:"password" binding:"required,min=8,max=32"`
	Nickname      string `json:"nickname"`
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

	// 验证教务账号（通过 EduHandler 的逻辑）
	eduHandler := NewEduHandler(h.db)
	
	// 临时创建用户记录用于绑定教务信息（后面会完善）
	var user models.User
	user.StudentID = input.StudentID
	user.Nickname = input.Nickname
	if user.Nickname == "" {
		user.Nickname = input.StudentID
	}
	user.Role = models.RoleUser
	user.CreditScore = 100

	// 尝试验证教务密码
	client := resty.New()
	csrfToken, err := getIndexCookieAndCsrfToken(client)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "无法连接教务系统，请检查网络"})
		return
	}

	publicKey, err := getPublicKey(client)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "获取加密密钥失败，教务系统可能正在维护"})
		return
	}

	encryptedPassword, err := rsaByPublicKey(input.EduPassword, publicKey)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "密码加密失败"})
		return
	}

	cookies, err := syluLogin(client, input.StudentID, encryptedPassword, csrfToken)
	if err != nil {
		c.JSON(http.StatusUnauthorized, gin.H{"error": "教务密码错误"})
		return
	}

	cookieStr := buildCookieString(cookies[1:2])

	// 获取学生信息
	grade, college, major, _ := getStudentInfo(client, cookieStr, input.StudentID)

	// 哈希App密码
	hashedPassword, err := bcrypt.GenerateFromPassword([]byte(input.Password), bcrypt.DefaultCost)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "密码加密失败"})
		return
	}

	// 创建用户
	user.PasswordHash = string(hashedPassword)
	user.EduStudentID = input.StudentID
	user.EduPassword = input.EduPassword
	user.EduCookie = cookieStr
	user.EduBound = true
	user.EduGrade = grade
	user.EduCollege = college
	user.EduMajor = major

	if err := h.db.Create(&user).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "创建用户失败"})
		return
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

// 以下是从 edu.go 复制的辅助函数（用于 RegisterWithEdu）

func baseHttpHeaders() map[string]string {
	return map[string]string{
		"User-Agent":    "Mozilla/5.0 (Windows NT 6.1; WOW64; rv:29.0) Gecko/20100101 Firefox/29.0",
		"Content-Type":  "application/x-www-form-urlencoded;charset=uft-8",
		"Cache-Control": "no-cache",
	}
}

func nowTime() string {
	return strconv.FormatInt(time.Now().UnixMilli(), 10)
}

func getIndexCookieAndCsrfToken(client *resty.Client) (string, error) {
	client.SetTimeout(3 * time.Second)
	indexUrl := "https://jxw.sylu.edu.cn/xtgl"

	initResp, err := client.R().SetHeaders(baseHttpHeaders()).Get(indexUrl + "/login_slogin.html")
	if err != nil {
		if urlErr, ok := err.(*url.Error); ok && urlErr.Timeout() {
			return getIndexCookieAndCsrfToken(client)
		}
		return "", err
	}

	findCsrfToken := regexp.MustCompile(`id="csrftoken" name="csrftoken" value="([^"]+)"`)
	matches := findCsrfToken.FindStringSubmatch(string(initResp.Body()))
	if len(matches) < 2 {
		return "", errors.New("无法获取csrf token")
	}

	client.Cookies = initResp.Cookies()
	return matches[1], nil
}

func getPublicKey(client *resty.Client) (*PublicKey, error) {
	indexUrl := "https://jxw.sylu.edu.cn/xtgl"
	resp, err := client.R().SetHeaders(baseHttpHeaders()).
		SetQueryParams(map[string]string{
			"time": nowTime(),
			"_":    nowTime(),
		}).Get(indexUrl + "/login_getPublicKey.html")

	if err != nil {
		return nil, err
	}

	var publicKey PublicKey
	if err := json.Unmarshal(resp.Body(), &publicKey); err != nil {
		return nil, err
	}
	return &publicKey, nil
}

type PublicKey struct {
	Modulus  string `json:"modulus"`
	Exponent string `json:"exponent"`
}

func rsaByPublicKey(password string, publicKey *PublicKey) (string, error) {
	modulusBytes, err := base64.StdEncoding.DecodeString(publicKey.Modulus)
	if err != nil {
		return "", err
	}

	exponentBytes, err := base64.StdEncoding.DecodeString(publicKey.Exponent)
	if err != nil {
		return "", err
	}

	pubKey := &rsa.PublicKey{
		N: new(big.Int).SetBytes(modulusBytes),
		E: int(new(big.Int).SetBytes(exponentBytes).Int64()),
	}

	encryptedBytes, err := rsa.EncryptPKCS1v15(rand.Reader, pubKey, []byte(password))
	if err != nil {
		return "", err
	}

	return base64.StdEncoding.EncodeToString(encryptedBytes), nil
}

func syluLogin(client *resty.Client, studentID, encryptedPassword, csrfToken string) ([]*http.Cookie, error) {
	indexUrl := "https://jxw.sylu.edu.cn/xtgl"
	loginResp, err := client.SetRedirectPolicy(resty.NoRedirectPolicy()).R().
		SetFormData(map[string]string{
			"csrftoken": csrfToken,
			"language":  "zh_CN",
			"yhm":       studentID,
			"mm":        encryptedPassword,
		}).
		SetQueryParam("time", nowTime()).
		SetHeaders(baseHttpHeaders()).
		Post(indexUrl + "/login_slogin.html")

	if err != nil && err.Error() == "post redirect disabled" {
		return loginResp.Cookies(), nil
	} else if err != nil {
		return nil, errors.New("服务器连接失败:" + err.Error())
	}
	return nil, errors.New("账号或密码错误")
}

func buildCookieString(cookies []*http.Cookie) string {
	var parts []string
	for _, c := range cookies {
		parts = append(parts, c.Name+"="+c.Value)
	}
	return strings.Join(parts, "; ")
}

func getStudentInfo(client *resty.Client, cookie, studentID string) (grade, college, major string, err error) {
	client.SetHostURL("https://jxw.sylu.edu.cn/xtgl")
	defer client.GetClient().CloseIdleConnections()

	resp, err := client.R().
		SetHeader("Cookie", cookie).
		SetHeaders(baseHttpHeaders()).
		Get("/grxx_cxGrxx.html?gnmkdm=N100501&layout=default")

	if err != nil {
		return "", "", "", err
	}

	body := string(resp.Body())

	gradeRe := regexp.MustCompile(`年级[：:]\s*(\d{4})`)
	gradeMatch := gradeRe.FindStringSubmatch(body)
	if len(gradeMatch) > 1 {
		grade = gradeMatch[1]
	}

	collegeRe := regexp.MustCompile(`学院[：:]\s*([^\s<]+)`)
	collegeMatch := collegeRe.FindStringSubmatch(body)
	if len(collegeMatch) > 1 {
		college = collegeMatch[1]
	}

	majorRe := regexp.MustCompile(`专业[：:]\s*([^\s<]+)`)
	majorMatch := majorRe.FindStringSubmatch(body)
	if len(majorMatch) > 1 {
		major = majorMatch[1]
	}

	if grade == "" {
		gradeRe2 := regexp.MustCompile(`(\d{4})-(\d{4})`)
		gradeMatch2 := gradeRe2.FindStringSubmatch(body)
		if len(gradeMatch2) > 0 {
			grade = gradeMatch2[1]
		}
	}

	return grade, college, major, nil
}
