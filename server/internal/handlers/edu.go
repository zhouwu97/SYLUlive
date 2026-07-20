package handlers

import (
	"context"
	"crypto/rand"
	"crypto/rsa"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"math/big"
	"net/http"
	"net/url"
	"regexp"
	"strconv"
	"strings"
	"time"

	"shenliyuan/internal/models"

	"github.com/gin-gonic/gin"
	"github.com/go-resty/resty/v2"
	"gorm.io/gorm"
)

const (
	indexUrl  = "https://jxw.sylu.edu.cn/xtgl"
	courseUrl = "https://jxw.sylu.edu.cn/kbcx"
	gradeUrl  = "https://jxw.sylu.edu.cn/cjcx"

	legacyCourseCacheRetiredCode = "COURSE_CACHE_RETIRED"
	legacyCourseCacheRetiredText = "服务器课表缓存已退役，请升级客户端后重新同步课表"
)

var (
	Error302          = errors.New("post redirect disabled")
	ErrorLapse        = errors.New("cookie已失效")
	ErrorCourseNoOpen = errors.New("当前学期课表暂未排课")
	ErrorGradesNoOpen = errors.New("当前学期暂无成绩")
)

type eduLoginError struct {
	Code    string
	Message string
}

func (e *eduLoginError) Error() string {
	return e.Message
}

// PublicKey 公钥结构
type PublicKey struct {
	Modulus  string `json:"modulus"`
	Exponent string `json:"exponent"`
}

// EduHandler 教务处理器
type EduHandler struct {
	db *gorm.DB
}

// NewEduHandler 创建教务处理器
func NewEduHandler(db *gorm.DB) *EduHandler {
	return &EduHandler{db: db}
}

// baseHttpHeaders 请求头
func baseHttpHeaders() map[string]string {
	return map[string]string{
		"User-Agent":    "Mozilla/5.0 (Windows NT 6.1; WOW64; rv:29.0) Gecko/20100101 Firefox/29.0",
		"Content-Type":  "application/x-www-form-urlencoded;charset=utf-8",
		"Cache-Control": "no-cache",
	}
}

// nowTime 获取当前时间戳
func nowTime() string {
	return strconv.FormatInt(time.Now().UnixMilli(), 10)
}

// ---------- 统一的 Python 教务服务错误映射 ----------

// EduServiceError Python 教务服务返回的错误结构
type EduServiceError struct {
	Detail json.RawMessage `json:"detail"`
	Error  string          `json:"error"`
	Code   string          `json:"code"`
}

type eduServiceRequestError struct {
	statusCode int
	body       []byte
	err        error
}

func (e *eduServiceRequestError) Error() string {
	if e.err != nil {
		return e.err.Error()
	}
	return "教务服务请求失败"
}

// pythonEduRequest 是 Go 到国内教务服务的唯一调用出口。
// 用户身份只从已认证的 Gin 上下文推导，并通过内部请求头传递。
func pythonEduRequest(method, path string, userID *uint, body interface{}) (*resty.Response, error) {
	client := resty.New().SetTimeout(30 * time.Second)
	req := client.R().SetHeader("Content-Type", "application/json").
		SetHeader("X-Internal-Service-Token", EduServiceConfig.Token)
	if userID != nil {
		req.SetHeader("X-Internal-User-ID", strconv.FormatUint(uint64(*userID), 10))
	}
	if body != nil {
		req.SetBody(body)
	}
	return req.Execute(method, strings.TrimRight(EduServiceConfig.BaseURL, "/")+path)
}

// PythonEduCredentialCleanupRemote 将本地已提交的撤销授权补偿到教务服务。
type PythonEduCredentialCleanupRemote struct{}

// Unbind 删除教务服务保存的凭证副本；接口失败由 outbox 记录后重试。
func (PythonEduCredentialCleanupRemote) Unbind(ctx context.Context, userID uint) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	response, err := pythonEduRequest(http.MethodDelete, "/api/edu/bind", &userID, nil)
	if err != nil {
		return err
	}
	if response.StatusCode() != http.StatusOK {
		return fmt.Errorf("教务服务解绑失败，状态码: %d", response.StatusCode())
	}
	return ctx.Err()
}

type eduBindResult struct {
	Success   bool   `json:"success"`
	Message   string `json:"message"`
	Code      string `json:"code"`
	StudentID string `json:"student_id"`
	Name      string `json:"name"`
	Grade     string `json:"grade"`
	College   string `json:"college"`
	Major     string `json:"major"`
}

type eduStatusResult struct {
	Bound     bool   `json:"bound"`
	StudentID string `json:"student_id"`
	Name      string `json:"name"`
	Grade     string `json:"grade"`
	College   string `json:"college"`
	Major     string `json:"major"`
}

func bindEduWithPython(userID uint, studentID, password string) (*eduBindResult, error) {
	resp, err := pythonEduRequest(http.MethodPost, "/api/edu/bind", &userID, map[string]string{
		"student_id": studentID,
		"password":   password,
	})
	if err != nil {
		return nil, &eduServiceRequestError{err: err}
	}
	if resp.StatusCode() != http.StatusOK {
		return nil, &eduServiceRequestError{statusCode: resp.StatusCode(), body: resp.Body()}
	}

	var result eduBindResult
	if err := json.Unmarshal(resp.Body(), &result); err != nil || !result.Success {
		if err == nil {
			err = errors.New("教务服务未确认绑定成功")
		}
		return nil, &eduServiceRequestError{statusCode: http.StatusBadGateway, body: resp.Body(), err: err}
	}
	return &result, nil
}

func updateUserEduBinding(db *gorm.DB, userID uint, studentID string, result *eduBindResult) error {
	return db.Model(&models.User{}).Where("id = ?", userID).Updates(map[string]interface{}{
		"edu_student_id": studentID,
		"edu_password":   "",
		"edu_cookie":     "",
		"edu_bound":      true,
		"edu_grade":      result.Grade,
		"edu_college":    result.College,
		"edu_major":      result.Major,
	}).Error
}

func writeEduServiceError(c *gin.Context, err error) {
	var requestErr *eduServiceRequestError
	if errors.As(err, &requestErr) {
		if requestErr.statusCode > 0 {
			mapEduServiceError(c, requestErr.statusCode, requestErr.body)
			return
		}
		c.JSON(http.StatusBadGateway, gin.H{"error": "无法连接教务服务，请稍后再试"})
		return
	}
	c.JSON(http.StatusBadGateway, gin.H{"error": "教务服务请求失败"})
}

// mapEduServiceError 将 Python 教务服务的响应状态码和 body 映射为前端可用的响应。
// 对非登录问题保留原始语义：503 → 503, 非 JSON → 502, 真正 Cookie 过期 → 409。
func mapEduServiceError(c *gin.Context, statusCode int, body []byte) {
	var svcErr EduServiceError
	if err := json.Unmarshal(body, &svcErr); err != nil || (len(svcErr.Detail) == 0 && svcErr.Error == "") {
		svcErr.Error = string(body)
	}

	msg := ""
	if len(svcErr.Detail) > 0 {
		if err := json.Unmarshal(svcErr.Detail, &msg); err != nil {
			var detail struct {
				Message string `json:"message"`
				Code    string `json:"code"`
			}
			if json.Unmarshal(svcErr.Detail, &detail) == nil {
				msg = detail.Message
				if svcErr.Code == "" {
					svcErr.Code = detail.Code
				}
			}
		}
	}
	if msg == "" {
		msg = svcErr.Error
	}
	if msg == "" {
		msg = "教务服务异常"
	}

	switch statusCode {
	case http.StatusUnauthorized:
		// 只有明确的会话过期才提示客户端重绑；绑定密码错误仍应保持 401。
		if svcErr.Code == "SESSION_EXPIRED" {
			c.JSON(http.StatusConflict, gin.H{
				"code":          "EDU_SESSION_EXPIRED",
				"error":         msg,
				"upstream_code": svcErr.Code,
			})
			return
		}
		c.JSON(http.StatusUnauthorized, gin.H{
			"error":         msg,
			"upstream_code": svcErr.Code,
		})
	case http.StatusServiceUnavailable, http.StatusBadGateway:
		c.JSON(statusCode, gin.H{
			"error":         msg,
			"upstream_code": svcErr.Code,
		})
	default:
		if statusCode >= 500 {
			c.JSON(statusCode, gin.H{
				"error":         msg,
				"upstream_code": svcErr.Code,
			})
		} else {
			c.JSON(statusCode, gin.H{
				"error":         msg,
				"upstream_code": svcErr.Code,
			})
		}
	}
}

// BindEduInput 绑定教务输入
type BindEduInput struct {
	StudentID string `json:"student_id" binding:"required,len=10"`
	Password  string `json:"password" binding:"required"`
}

// BindEdu 绑定教务账号
func (h *EduHandler) BindEdu(c *gin.Context) {
	userID := c.GetUint("user_id")

	var input BindEduInput
	if err := c.ShouldBindJSON(&input); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "参数错误: " + err.Error()})
		return
	}

	result, err := bindEduWithPython(userID, input.StudentID, input.Password)
	if err != nil {
		writeEduServiceError(c, err)
		return
	}
	if err := updateUserEduBinding(h.db, userID, input.StudentID, result); err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "同步教务绑定状态失败"})
		return
	}

	c.JSON(http.StatusOK, gin.H{
		"message":        "绑定成功",
		"edu_student_id": input.StudentID,
		"name":           result.Name,
		"edu_grade":      result.Grade,
		"edu_college":    result.College,
		"edu_major":      result.Major,
	})
}

// UnbindEdu 解绑教务账号
func (h *EduHandler) UnbindEdu(c *gin.Context) {
	userID := c.GetUint("user_id")
	resp, err := pythonEduRequest(http.MethodDelete, "/api/edu/bind", &userID, nil)
	if err != nil {
		writeEduServiceError(c, &eduServiceRequestError{err: err})
		return
	}
	if resp.StatusCode() != http.StatusOK {
		mapEduServiceError(c, resp.StatusCode(), resp.Body())
		return
	}

	if err := h.db.Model(&models.User{}).Where("id = ?", userID).Updates(map[string]interface{}{
		"edu_student_id": "",
		"edu_password":   "",
		"edu_cookie":     "",
		"edu_bound":      false,
		"edu_grade":      "",
		"edu_college":    "",
		"edu_major":      "",
	}).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "同步教务解绑状态失败"})
		return
	}

	c.JSON(http.StatusOK, gin.H{"message": "解绑成功"})
}

// GetEduStatus 获取教务绑定状态
func (h *EduHandler) GetEduStatus(c *gin.Context) {
	userID := c.GetUint("user_id")
	resp, err := pythonEduRequest(http.MethodGet, "/api/edu/status", &userID, nil)
	if err != nil {
		writeEduServiceError(c, &eduServiceRequestError{err: err})
		return
	}
	if resp.StatusCode() != http.StatusOK {
		mapEduServiceError(c, resp.StatusCode(), resp.Body())
		return
	}
	var status eduStatusResult
	if err := json.Unmarshal(resp.Body(), &status); err != nil {
		c.JSON(http.StatusBadGateway, gin.H{"error": "教务服务返回异常"})
		return
	}
	updates := map[string]interface{}{"edu_bound": status.Bound}
	if status.Bound {
		updates["edu_student_id"] = status.StudentID
		updates["edu_grade"] = status.Grade
		updates["edu_college"] = status.College
		updates["edu_major"] = status.Major
	} else {
		updates["edu_student_id"] = ""
		updates["edu_password"] = ""
		updates["edu_cookie"] = ""
		updates["edu_grade"] = ""
		updates["edu_college"] = ""
		updates["edu_major"] = ""
	}
	if err := h.db.Model(&models.User{}).Where("id = ?", userID).Updates(updates).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "同步教务状态失败"})
		return
	}

	c.JSON(http.StatusOK, gin.H{
		"edu_bound":      status.Bound,
		"edu_student_id": status.StudentID,
		"name":           status.Name,
		"edu_grade":      status.Grade,
		"edu_college":    status.College,
		"edu_major":      status.Major,
	})
}

// PreVerifyInput 注册前验证教务输入
type PreVerifyInput struct {
	StudentID string `json:"student_id" binding:"required,len=10"`
	Password  string `json:"password" binding:"required"`
}

// PreVerify 注册前验证教务账号（不依赖用户登录状态）
func (h *EduHandler) PreVerify(c *gin.Context) {
	var input PreVerifyInput
	if err := c.ShouldBindJSON(&input); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "参数错误"})
		return
	}

	// 检查学号是否已被注册
	var count int64
	h.db.Model(&models.User{}).Where("student_id = ?", input.StudentID).Count(&count)
	if count > 0 {
		c.JSON(http.StatusBadRequest, gin.H{"error": "该学号已注册，请直接登录", "success": false})
		return
	}

	resp, err := pythonEduRequest(http.MethodPost, "/api/edu/pre_verify", nil, map[string]string{
		"student_id": input.StudentID,
		"password":   input.Password,
	})
	if err != nil {
		writeEduServiceError(c, &eduServiceRequestError{err: err})
		return
	}
	if !json.Valid(resp.Body()) {
		c.JSON(http.StatusBadGateway, gin.H{"error": "教务服务返回异常", "success": false})
		return
	}
	c.Data(resp.StatusCode(), "application/json; charset=utf-8", resp.Body())
}

// CourseInput 课表查询输入
type CourseInput struct {
	Year     string `json:"year" binding:"required"`
	Semester int    `json:"semester" binding:"required,oneof=3 12"`
}

// GetCourses 获取课表（通过Python服务访问教务系统）
func (h *EduHandler) GetCourses(c *gin.Context) {
	userID, _ := c.Get("user_id")

	if err := h.db.First(&models.User{}, userID).Error; err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "用户不存在"})
		return
	}

	var input CourseInput
	if err := c.ShouldBindJSON(&input); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
		return
	}

	// 通过Python服务获取课表（Go在香港无法直接访问教务系统）
	client := resty.New()
	client.SetTimeout(30 * time.Second)

	resp, err := client.R().
		SetHeader("Content-Type", "application/json").
		SetHeader("X-Internal-Service-Token", EduServiceConfig.Token).
		SetHeader("X-Internal-User-ID", fmt.Sprintf("%d", userID)).
		SetBody(map[string]interface{}{
			"user_id":  fmt.Sprintf("%d", userID),
			"year":     input.Year,
			"semester": input.Semester,
		}).
		Post(EduServiceConfig.BaseURL + "/api/edu/courses/fetch")

	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "无法连接教务服务，请检查网络"})
		return
	}

	if resp.StatusCode() != 200 {
		mapEduServiceError(c, resp.StatusCode(), resp.Body())
		return
	}

	// 防止Python返回200+非JSON导致Flutter解析异常
	if !json.Valid(resp.Body()) {
		log.Printf(
			"[EDU] courses returned non-JSON: status=%d content_type=%q",
			resp.StatusCode(),
			resp.Header().Get("Content-Type"),
		)
		c.JSON(http.StatusBadGateway, gin.H{
			"error": "教务服务返回异常，请稍后再试",
		})
		return
	}

	// 直接透传给前端
	c.Data(http.StatusOK, "application/json", resp.Body())
}

// RetiredCourseCache 为旧客户端提供明确的迁移响应。
//
// 课表原始数据只能保存在当前客户端账号隔离的加密保险箱中，服务端不再
// 接受上传、读取历史副本或代理这些副本。
func (h *EduHandler) RetiredCourseCache(c *gin.Context) {
	c.JSON(http.StatusGone, gin.H{
		"code":      legacyCourseCacheRetiredCode,
		"error":     legacyCourseCacheRetiredText,
		"action":    "upgrade_client",
		"retryable": false,
	})
}

// GradesInput 成绩查询输入
type GradesInput struct {
	Year     string `json:"year" binding:"required"`
	Semester int    `json:"semester" binding:"required,oneof=3 12"`
}

// GradeDetailInput 单门课程成绩明细输入
type GradeDetailInput struct {
	Year           string `json:"year" binding:"required"`
	Semester       int    `json:"semester" binding:"required,oneof=3 12"`
	ClassID        string `json:"class_id" binding:"required"`
	CourseName     string `json:"course_name" binding:"required"`
	CourseID       string `json:"course_id"`
	StudentGradeID string `json:"student_grade_id"`
}

// AcademicSituationInput 学业情况查询输入
type AcademicSituationInput struct {
	ForceRefresh bool `json:"force_refresh"`
}

// GetGrades 获取成绩（通过Python服务访问教务系统）
func (h *EduHandler) GetGrades(c *gin.Context) {
	userID, _ := c.Get("user_id")

	if err := h.db.First(&models.User{}, userID).Error; err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "用户不存在"})
		return
	}

	var input GradesInput
	if err := c.ShouldBindJSON(&input); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
		return
	}

	// 通过Python服务获取成绩
	client := resty.New()
	client.SetTimeout(30 * time.Second)

	resp, err := client.R().
		SetHeader("Content-Type", "application/json").
		SetHeader("X-Internal-Service-Token", EduServiceConfig.Token).
		SetHeader("X-Internal-User-ID", fmt.Sprintf("%d", userID)).
		SetBody(map[string]interface{}{
			"user_id":  fmt.Sprintf("%d", userID),
			"year":     input.Year,
			"semester": input.Semester,
		}).
		Post(strings.TrimRight(EduServiceConfig.BaseURL, "/") + "/api/edu/grades/")

	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "无法连接教务服务，请检查网络"})
		return
	}

	// 防止Python返回非JSON导致Flutter FormatException
	if !json.Valid(resp.Body()) {
		log.Printf(
			"[EDU] grades returned non-JSON: status=%d content_type=%q",
			resp.StatusCode(),
			resp.Header().Get("Content-Type"),
		)
		c.JSON(http.StatusBadGateway, gin.H{
			"error": "教务服务返回异常，请稍后再试",
		})
		return
	}

	if resp.StatusCode() != 200 {
		mapEduServiceError(c, resp.StatusCode(), resp.Body())
		return
	}

	c.Data(resp.StatusCode(), "application/json; charset=utf-8", resp.Body())
}

// GetAcademicSituation 获取官方学生学业情况（通过Python服务访问教务系统）
func (h *EduHandler) GetAcademicSituation(c *gin.Context) {
	userID, _ := c.Get("user_id")

	if err := h.db.First(&models.User{}, userID).Error; err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "用户不存在"})
		return
	}

	var input AcademicSituationInput
	if err := c.ShouldBindJSON(&input); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
		return
	}

	client := resty.New()
	client.SetTimeout(45 * time.Second)

	resp, err := client.R().
		SetHeader("Content-Type", "application/json").
		SetHeader("X-Internal-Service-Token", EduServiceConfig.Token).
		SetHeader("X-Internal-User-ID", fmt.Sprintf("%d", userID)).
		SetBody(map[string]interface{}{
			"user_id":       fmt.Sprintf("%d", userID),
			"force_refresh": input.ForceRefresh,
		}).
		Post(strings.TrimRight(EduServiceConfig.BaseURL, "/") + "/api/edu/academic-situation/")

	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "无法连接教务服务，请检查网络"})
		return
	}

	if !json.Valid(resp.Body()) {
		log.Printf(
			"[EDU] academic situation returned non-JSON: status=%d content_type=%q",
			resp.StatusCode(),
			resp.Header().Get("Content-Type"),
		)
		c.JSON(http.StatusBadGateway, gin.H{
			"error": "教务服务返回异常，请稍后再试",
		})
		return
	}

	if resp.StatusCode() != 200 {
		mapEduServiceError(c, resp.StatusCode(), resp.Body())
		return
	}

	c.Data(resp.StatusCode(), "application/json; charset=utf-8", resp.Body())
}

// GetGradeDetail 获取单门课程成绩构成（通过Python服务访问教务系统）
func (h *EduHandler) GetGradeDetail(c *gin.Context) {
	userID, _ := c.Get("user_id")

	if err := h.db.First(&models.User{}, userID).Error; err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "用户不存在"})
		return
	}

	var input GradeDetailInput
	if err := c.ShouldBindJSON(&input); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
		return
	}

	client := resty.New()
	client.SetTimeout(30 * time.Second)

	resp, err := client.R().
		SetHeader("Content-Type", "application/json").
		SetHeader("X-Internal-Service-Token", EduServiceConfig.Token).
		SetHeader("X-Internal-User-ID", fmt.Sprintf("%d", userID)).
		SetBody(map[string]interface{}{
			"user_id":          fmt.Sprintf("%d", userID),
			"year":             input.Year,
			"semester":         input.Semester,
			"class_id":         input.ClassID,
			"course_name":      input.CourseName,
			"course_id":        input.CourseID,
			"student_grade_id": input.StudentGradeID,
		}).
		Post(strings.TrimRight(EduServiceConfig.BaseURL, "/") + "/api/edu/grades/detail")

	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "无法连接教务服务，请检查网络"})
		return
	}

	if !json.Valid(resp.Body()) {
		log.Printf(
			"[EDU] grade detail returned non-JSON: status=%d content_type=%q",
			resp.StatusCode(),
			resp.Header().Get("Content-Type"),
		)
		c.JSON(http.StatusBadGateway, gin.H{
			"error": "教务服务返回异常，请稍后再试",
		})
		return
	}

	if resp.StatusCode() != 200 {
		mapEduServiceError(c, resp.StatusCode(), resp.Body())
		return
	}

	c.Data(resp.StatusCode(), "application/json; charset=utf-8", resp.Body())
}

// 以下是整合的教务系统登录和查询逻辑

func getIndexCookieAndCsrfToken(client *resty.Client, retryCount int) (string, error) {
	if retryCount >= 5 {
		return "", errors.New("教务系统连接超时，多次重试失败")
	}
	client.SetTimeout(3 * time.Second)

	initResp, err := client.R().SetHeaders(baseHttpHeaders()).Get(indexUrl + "/login_slogin.html")
	if err != nil {
		if urlErr, ok := err.(*url.Error); ok && urlErr.Timeout() {
			return getIndexCookieAndCsrfToken(client, retryCount+1)
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

func classifyEduLoginFailure(statusCode int, body string) error {
	if strings.Contains(body, "用户名或密码错误") ||
		strings.Contains(body, "账号或密码错误") ||
		strings.Contains(body, "账户或密码错误") ||
		strings.Contains(body, "账号密码错误") ||
		strings.Contains(body, "密码错误") ||
		strings.Contains(body, "密码不正确") ||
		strings.Contains(body, "用户不存在") {
		return &eduLoginError{Code: "INVALID_CREDENTIALS", Message: "教务账号或密码错误"}
	}
	if statusCode == http.StatusOK {
		return &eduLoginError{Code: "UNKNOWN_LOGIN_STATE", Message: "学校登录状态未知，请稍后重试或联系管理员"}
	}
	if statusCode >= 500 || statusCode == 0 {
		return &eduLoginError{Code: "REMOTE_SYSTEM_UNAVAILABLE", Message: "学校教务系统暂时不可用，请稍后再试"}
	}
	return &eduLoginError{Code: "CAS_FLOW_CHANGED", Message: "学校登录页面可能发生变化，请稍后重试或联系管理员"}
}

func summarizeEduLoginFailureBody(body string) (string, string) {
	title := ""
	if matches := regexp.MustCompile(`(?is)<title[^>]*>(.*?)</title>`).FindStringSubmatch(body); len(matches) > 1 {
		title = strings.Join(strings.Fields(matches[1]), " ")
	}

	text := regexp.MustCompile(`(?is)<script[^>]*>.*?</script>|<style[^>]*>.*?</style>`).ReplaceAllString(body, " ")
	text = regexp.MustCompile(`(?s)<[^>]+>`).ReplaceAllString(text, " ")
	text = strings.Join(strings.Fields(text), " ")
	runes := []rune(text)
	if len(runes) > 120 {
		text = string(runes[:120])
	}

	return title, text
}

func logEduLoginFailure(resp *resty.Response, err error) {
	statusCode := 0
	finalURL := ""
	body := ""
	if resp != nil {
		statusCode = resp.StatusCode()
		body = string(resp.Body())
		if resp.RawResponse != nil && resp.RawResponse.Request != nil && resp.RawResponse.Request.URL != nil {
			finalURL = resp.RawResponse.Request.URL.Redacted()
		}
	}

	code := "UNKNOWN_LOGIN_STATE"
	var loginErr *eduLoginError
	if errors.As(err, &loginErr) {
		code = loginErr.Code
	}
	title, hint := summarizeEduLoginFailureBody(body)
	log.Printf("[EDU] login failed status=%d final_url=%q title=%q code=%s body_hint=%q", statusCode, finalURL, title, code, hint)
}

func syluLogin(client *resty.Client, studentID, encryptedPassword, csrfToken string) ([]*http.Cookie, error) {
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

	if err != nil && err.Error() == Error302.Error() {
		return loginResp.Cookies(), nil
	} else if err != nil {
		loginErr := &eduLoginError{Code: "REMOTE_SYSTEM_UNAVAILABLE", Message: "学校教务系统暂时不可用，请稍后再试"}
		logEduLoginFailure(loginResp, loginErr)
		return nil, loginErr
	}
	if loginResp == nil {
		loginErr := &eduLoginError{Code: "REMOTE_SYSTEM_UNAVAILABLE", Message: "学校教务系统暂时不可用，请稍后再试"}
		logEduLoginFailure(nil, loginErr)
		return nil, loginErr
	}
	loginErr := classifyEduLoginFailure(loginResp.StatusCode(), string(loginResp.Body()))
	logEduLoginFailure(loginResp, loginErr)
	return nil, loginErr
}

func buildCookieString(cookies []*http.Cookie) string {
	var parts []string
	for _, c := range cookies {
		parts = append(parts, c.Name+"="+c.Value)
	}
	return strings.Join(parts, "; ")
}

// scheduleResponse 课表响应结构（匹配教务系统JSON字段）
type scheduleResponse struct {
	RqazcList []struct {
		Rq string `json:"rq"`
	} `json:"rqazcList"`
	KbList []struct {
		Name     string `json:"kcmc"` // 课程名称
		Teacher  string `json:"xm"`   // 教师姓名
		Location string `json:"cdmc"` // 场地名称
		Time     string `json:"jc"`   // 节次
		WeekDay  string `json:"xqj"`  // 星期几
		WeekS    string `json:"zcd"`  // 周段
	} `json:"kbList"`
}

type courseResponse struct {
	Courses []courseInfo `json:"courses"`
}

type courseInfo struct {
	Name     string `json:"name"`
	Teacher  string `json:"teacher"`
	Location string `json:"location"`
	Time     int    `json:"time"`
	WeekDay  int    `json:"week_day"`
	WeekS    []int  `json:"weeks"`
}

func getCourseByInfo(client *resty.Client, cookie, year string, semester int) (*courseResponse, error) {
	client.SetHostURL(courseUrl)
	defer client.GetClient().CloseIdleConnections()

	formData := map[string]string{
		"xnm":    year,
		"zs":     "1",
		"doType": "app",
		"xqm":    strconv.Itoa(semester),
		"kblx":   "1",
	}

	resp, err := client.R().
		SetFormData(formData).
		SetHeader("Cookie", cookie).
		Post("/xskbcxMobile_cxXsKb.html?gnmkdm=N2154")

	if err != nil {
		return nil, err
	}

	if string(resp.Body()) == "null" {
		return nil, ErrorLapse
	}

	var schedule scheduleResponse
	if err := json.Unmarshal(resp.Body(), &schedule); err != nil {
		return nil, err
	}

	if len(schedule.KbList) == 0 {
		return nil, ErrorCourseNoOpen
	}

	result := &courseResponse{Courses: make([]courseInfo, 0, len(schedule.KbList))}

	for _, v := range schedule.KbList {
		course := courseInfo{
			Name:     v.Name,
			Teacher:  v.Teacher,
			Location: v.Location,
			Time:     timeToInt(v.Time),
			WeekDay:  parseWeekday(v.WeekDay),
			WeekS:    parseWeeks(v.WeekS),
		}
		result.Courses = append(result.Courses, course)
	}

	return result, nil
}

// 成绩相关结构（匹配教务系统JSON字段）
type gradesResponse struct {
	Items []struct {
		Kcmc   string `json:"KCMC"`   // 课程名称
		JxbID  string `json:"JXBID"`  // 教学班ID
		Jsxm   string `json:"JSXM"`   // 教师姓名
		Sfxwkc string `json:"SFXWKC"` // 是否学位课
		Xf     string `json:"XF"`     // 学分
		Jd     string `json:"JD"`     // 绩点
		Xfjd   string `json:"XFJD"`   // 学分绩点
		Bfzcj  string `json:"BFZCJ"`  // 百分成绩
		Cj     string `json:"CJ"`     // 成绩
	} `json:"items"`
}

type gradeInfo struct {
	Name        string  `json:"name"`
	ClassID     string  `json:"class_id"`
	Teacher     string  `json:"teacher"`
	IsDegree    bool    `json:"is_degree"`
	Credits     float64 `json:"credits"`
	GPA         float64 `json:"gpa"`
	GradePoints float64 `json:"grade_points"`
	Fraction    float64 `json:"fraction"`
	Grade       string  `json:"grade"`
}

func getGradesByInfo(client *resty.Client, cookie, year string, semester int) ([]gradeInfo, error) {
	client.SetHostURL(gradeUrl)
	defer client.GetClient().CloseIdleConnections()

	queryData := map[string]string{
		"doType": "query",
		"gnmkdm": "N305005",
	}

	formData := map[string]string{
		"xnm":                  year,
		"xqm":                  strconv.Itoa(semester),
		"queryModel.showCount": "30",
	}

	resp, err := client.R().
		SetQueryParams(queryData).
		SetFormData(formData).
		SetHeader("Cookie", cookie).
		Post("/cjcx_cxXsgrcj.html")

	if err != nil {
		return nil, err
	}

	if strings.Contains(string(resp.Header().Get("Content-Type")), "text/html") {
		return nil, ErrorLapse
	}

	var grades gradesResponse
	if err := json.Unmarshal(resp.Body(), &grades); err != nil {
		return nil, err
	}

	if len(grades.Items) < 1 {
		return nil, ErrorGradesNoOpen
	}

	result := make([]gradeInfo, 0, len(grades.Items))
	for _, v := range grades.Items {
		grade := gradeInfo{
			Name:     v.Kcmc,
			ClassID:  v.JxbID,
			Teacher:  v.Jsxm,
			IsDegree: v.Sfxwkc == "是",
		}
		grade.Credits, _ = strconv.ParseFloat(v.Xf, 64)
		grade.GPA, _ = strconv.ParseFloat(v.Jd, 64)
		grade.GradePoints, _ = strconv.ParseFloat(v.Xfjd, 64)
		grade.Fraction, _ = strconv.ParseFloat(v.Bfzcj, 64)
		grade.Grade = v.Cj
		result = append(result, grade)
	}

	return result, nil
}

func parseWeekday(s string) int {
	if v, err := strconv.Atoi(s); err == nil {
		return v
	}
	return 0
}

func parseWeeks(input string) []int {
	var weeks []int
	ranges := strings.Split(input, ",")
	for _, r := range ranges {
		re := regexp.MustCompile(`(\d+)`)
		bounds := re.FindAllString(r, -1)
		if len(bounds) > 1 {
			start, _ := strconv.Atoi(bounds[0])
			end, _ := strconv.Atoi(bounds[1])
			for i := start; i <= end; i++ {
				weeks = append(weeks, i)
			}
		} else if len(bounds) == 1 {
			start, _ := strconv.Atoi(bounds[0])
			weeks = append(weeks, start)
		}
	}
	return weeks
}

func timeToInt(time string) int {
	switch time {
	case "1-2节":
		return 1
	case "3-4节":
		return 2
	case "5-6节":
		return 3
	case "7-8节":
		return 4
	case "9-10节":
		return 5
	case "11-12节":
		return 6
	case "13-14节":
		return 7
	}
	return 0
}

// getStudentInfo 从教务系统获取学生基本信息
func getStudentInfo(client *resty.Client, cookie, studentID string) (grade, college, major string, err error) {
	client.SetHostURL("https://jxw.sylu.edu.cn/xtgl")
	defer client.GetClient().CloseIdleConnections()

	// 访问个人中心页面获取学生信息
	resp, err := client.R().
		SetHeader("Cookie", cookie).
		SetHeaders(baseHttpHeaders()).
		Get("/grxx_cxGrxx.html?gnmkdm=N100501&layout=default")

	if err != nil {
		return "", "", "", err
	}

	body := string(resp.Body())

	// 解析年级、学院、专业
	// 使用正则匹配
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

	// 如果解析不到，尝试从URL参数或页面其他地方获取
	if grade == "" {
		gradeRe2 := regexp.MustCompile(`(\d{4})-(\d{4})`)
		gradeMatch2 := gradeRe2.FindStringSubmatch(body)
		if len(gradeMatch2) > 0 {
			grade = gradeMatch2[1]
		}
	}

	return grade, college, major, nil
}

// refreshCookie 自动刷新过期的Cookie
func (h *EduHandler) refreshCookie(userID uint) (string, error) {
	var user models.User
	if err := h.db.First(&user, userID).Error; err != nil {
		return "", err
	}

	if !user.EduBound || user.EduStudentID == "" || user.EduPassword == "" {
		return "", errors.New("未绑定教务账号")
	}

	client := resty.New()

	csrfToken, err := getIndexCookieAndCsrfToken(client, 0)
	if err != nil {
		return "", err
	}

	publicKey, err := getPublicKey(client)
	if err != nil {
		return "", err
	}

	encryptedPassword, err := rsaByPublicKey(user.EduPassword, publicKey)
	if err != nil {
		return "", err
	}

	_, err = syluLogin(client, user.EduStudentID, encryptedPassword, csrfToken)
	if err != nil {
		return "", err
	}

	var cookieStr string
	if len(client.Cookies) > 1 {
		cookieStr = buildCookieString(client.Cookies[1:2])
	} else if len(client.Cookies) == 1 {
		cookieStr = buildCookieString(client.Cookies)
	}

	h.db.Model(&user).Updates(map[string]interface{}{
		"edu_cookie": cookieStr,
	})

	return cookieStr, nil
}
