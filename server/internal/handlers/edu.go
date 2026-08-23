package handlers

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"net/http"
	"os"
	"regexp"
	"strconv"
	"strings"
	"time"

	"shenliyuan/internal/academic"
	"shenliyuan/internal/middleware"
	"shenliyuan/internal/models"
	"shenliyuan/internal/services"
	"shenliyuan/internal/utils"

	"github.com/gin-gonic/gin"
	"github.com/go-resty/resty/v2"
	"gorm.io/gorm"
	"gorm.io/gorm/clause"
)

const (
	courseUrl = "https://jxw.sylu.edu.cn/kbcx"
	gradeUrl  = "https://jxw.sylu.edu.cn/cjcx"

	legacyCourseCacheRetiredCode = "COURSE_CACHE_RETIRED"
	legacyCourseCacheRetiredText = "服务器课表缓存已退役，请升级客户端后重新同步课表"
)

var (
	ErrorLapse        = errors.New("cookie已失效")
	ErrorCourseNoOpen = errors.New("当前学期课表暂未排课")
	ErrorGradesNoOpen = errors.New("当前学期暂无成绩")
)

// eduLoginError 表示教务服务返回给客户端的可判定错误。
// 该类型只用于错误归类，实际教务登录由 Python 教务服务负责。
type eduLoginError struct {
	Code    string
	Message string
}

func (e *eduLoginError) Error() string {
	return e.Message
}

// EduHandler 教务处理器
type EduHandler struct {
	db              *gorm.DB
	jwtSecret       string
	cleanupJobs     *services.EduCredentialCleanupJobService
	academicFetcher *services.EduFetchOrchestrator
	runResumer      UserConsentRunResumer
}

// UserConsentRunResumer 在教务授权后的首次成功刷新完成时，恢复对应用户等待授权的 AI Run。
// Handler 只依赖这个最小接口，避免耦合 AI Runtime 的具体实现。
type UserConsentRunResumer interface {
	ResumeUserConsent(context.Context, uint) error
}

// NewEduHandler 创建教务处理器
func NewEduHandler(db *gorm.DB) *EduHandler {
	return &EduHandler{db: db}
}

// NewEduHandlerWithLifecycle 创建具备授权撤销补偿和 Token 刷新能力的教务处理器。
func NewEduHandlerWithLifecycle(db *gorm.DB, jwtSecret string, cleanupJobs *services.EduCredentialCleanupJobService) *EduHandler {
	return &EduHandler{db: db, jwtSecret: jwtSecret, cleanupJobs: cleanupJobs}
}

// NewEduHandlerWithAcademicFetch 创建使用统一快照和拉取编排器的教务处理器。
func NewEduHandlerWithAcademicFetch(db *gorm.DB, jwtSecret string, cleanupJobs *services.EduCredentialCleanupJobService, academicFetcher *services.EduFetchOrchestrator) *EduHandler {
	return &EduHandler{db: db, jwtSecret: jwtSecret, cleanupJobs: cleanupJobs, academicFetcher: academicFetcher}
}

// SetUserConsentRunResumer 在 AI Runtime 初始化完成后接入授权恢复回调。
// 未启用校园 Agent 时，教务刷新流程仍可独立运行。
func (h *EduHandler) SetUserConsentRunResumer(resumer UserConsentRunResumer) {
	h.runResumer = resumer
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

// Unbind 仅删除指定授权代次的远端凭据；接口失败由 outbox 记录后重试。
func (PythonEduCredentialCleanupRemote) Unbind(ctx context.Context, userID uint, generation uint, deleteIdentity bool) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	response, err := pythonEduRequest(http.MethodDelete, "/api/edu/authorization", &userID, map[string]interface{}{
		"expected_generation": generation,
		"delete_identity":     deleteIdentity,
	})
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

var (
	errEduStudentAlreadyBound      = errors.New("该学号已绑定其他账号")
	errEduStudentIdentityImmutable = errors.New("已认证学生不能绑定其他学号")
	errEduBindingStudentMismatch   = errors.New("待提交教务绑定的学号不一致")
)

type eduStatusResult struct {
	Bound                bool   `json:"bound"`
	Authorized           bool   `json:"authorized"`
	SessionState         string `json:"session_state"`
	AutoRelogin          bool   `json:"auto_relogin"`
	CredentialGeneration uint   `json:"credential_generation"`
	StudentID            string `json:"student_id"`
	Name                 string `json:"name"`
	Grade                string `json:"grade"`
	College              string `json:"college"`
	Major                string `json:"major"`
}

type eduSessionResult struct {
	Success      bool   `json:"success"`
	Message      string `json:"message"`
	Authorized   bool   `json:"authorized"`
	SessionState string `json:"session_state"`
	AutoRelogin  bool   `json:"auto_relogin"`
}

func bindEduWithPython(userID uint, studentID, password string, generation uint) (*eduBindResult, error) {
	resp, err := pythonEduRequest(http.MethodPost, "/api/edu/bind", &userID, map[string]interface{}{
		"student_id":            studentID,
		"password":              password,
		"credential_generation": generation,
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

// prepareEduBinding 在跨服务请求前持久化待绑定代次及目标学号。相同 pending 代次仅能由
// 同一学号重试，从而覆盖 Python 已成功、Go 进程尚未完成本地提交时的崩溃窗口。
func prepareEduBinding(db *gorm.DB, userID uint, studentID string) (uint, error) {
	studentID = strings.TrimSpace(studentID)
	if studentID == "" {
		return 0, errors.New("待绑定学号不能为空")
	}
	var generation uint
	err := db.Transaction(func(tx *gorm.DB) error {
		var user models.User
		if err := tx.Clauses(clause.Locking{Strength: "UPDATE"}).First(&user, userID).Error; err != nil {
			return err
		}
		if user.AccountStatus == "cancelled" || user.AccountStatus == "registration_cleanup_pending" {
			return errors.New("当前账号不能绑定教务")
		}
		if user.EduBindingState == "pending" && user.EduBindingPendingGeneration > user.EduAuthorizationGeneration {
			pendingStudentID := strings.TrimSpace(user.EduBindingPendingStudentID)
			if pendingStudentID == "" {
				// 兼容升级前已有的待绑定记录；已稳定认证的账号可从本地身份恢复目标学号。
				pendingStudentID = strings.TrimSpace(user.StudentID)
			}
			if pendingStudentID != "" && pendingStudentID != studentID {
				return errEduBindingStudentMismatch
			}
			if pendingStudentID == "" {
				if err := tx.Model(&models.User{}).Where("id = ?", userID).Update("edu_binding_pending_student_id", studentID).Error; err != nil {
					return err
				}
			}
			generation = user.EduBindingPendingGeneration
			return nil
		}
		generation = user.EduAuthorizationGeneration + 1
		now := time.Now()
		return tx.Model(&models.User{}).Where("id = ?", userID).Updates(map[string]interface{}{
			"edu_binding_state":              "pending",
			"edu_binding_pending_generation": generation,
			"edu_binding_pending_student_id": studentID,
			"edu_binding_started_at":         now,
		}).Error
	})
	return generation, err
}

func updateUserEduBinding(db *gorm.DB, userID uint, studentID string, result *eduBindResult, generation uint, recordBindingConsent bool) error {
	if result == nil || strings.TrimSpace(studentID) == "" {
		return errors.New("教务绑定结果无效")
	}
	if generation == 0 {
		return errors.New("教务授权代次无效")
	}
	studentID = strings.TrimSpace(studentID)
	now := time.Now()
	err := db.Transaction(func(tx *gorm.DB) error {
		var user models.User
		if err := tx.Clauses(clause.Locking{Strength: "UPDATE"}).First(&user, userID).Error; err != nil {
			return err
		}
		var conflict models.User
		err := tx.Clauses(clause.Locking{Strength: "UPDATE"}).
			Where("student_id = ? AND id <> ?", studentID, userID).First(&conflict).Error
		if err == nil {
			return errEduStudentAlreadyBound
		}
		if !errors.Is(err, gorm.ErrRecordNotFound) {
			return err
		}
		if user.StudentVerifiedAt != nil && user.StudentID != "" && user.StudentID != studentID {
			return errEduStudentIdentityImmutable
		}
		if user.AccountStatus == "cancelled" || user.AccountStatus == "registration_cleanup_pending" {
			return errors.New("当前账号不能绑定教务")
		}
		if user.EduBindingState == "active" && user.EduAuthorizationGeneration == generation && user.EduAuthorized && user.StudentID == studentID {
			// 相同请求已在先前尝试中完成本地提交；再次执行不得触发补偿删除新凭据。
			return nil
		}
		if user.EduBindingState != "pending" || user.EduBindingPendingGeneration != generation {
			return errors.New("教务授权待提交代次已变化")
		}
		updates := map[string]interface{}{
			"student_id":                     studentID,
			"student_verified_at":            now,
			"edu_student_id":                 studentID,
			"edu_authorized":                 true,
			"edu_session_state":              "active",
			"edu_auto_relogin":               true,
			"edu_authorized_at":              now,
			"edu_session_updated_at":         now,
			"edu_authorization_generation":   generation,
			"edu_cleanup_pending":            false,
			"edu_binding_state":              "active",
			"edu_binding_pending_generation": 0,
			"edu_binding_pending_student_id": "",
			"edu_binding_started_at":         nil,
			"edu_bound":                      true,
			"edu_password":                   "",
			"edu_cookie":                     "",
			"edu_grade":                      result.Grade,
			"edu_college":                    result.College,
			"edu_major":                      result.Major,
		}
		if user.AccountStatus == "registration_pending" {
			updates["account_status"] = "active"
		}
		if err := tx.Model(&models.User{}).Where("id = ?", userID).Updates(updates).Error; err != nil {
			return err
		}
		if err := tx.Model(&models.EduCredentialCleanupJob{}).
			Where("user_id = ? AND expected_generation < ? AND completed_at IS NULL", userID, generation).
			Updates(map[string]interface{}{"completed_at": now, "last_error": "已由新的教务授权代次替代", "locked_at": nil, "lock_token": ""}).Error; err != nil {
			return err
		}
		if recordBindingConsent {
			return recordEduBindingConsent(tx, userID)
		}
		return nil
	})
	if err != nil && (utils.IsPostgresUniqueViolation(err) || strings.Contains(strings.ToLower(err.Error()), "unique")) {
		return errEduStudentAlreadyBound
	}
	return err
}

// precheckEduBinding 在调用 Python 教务服务前确认稳定学号身份和归属没有冲突。
// 数据库唯一索引与 updateUserEduBinding 仍负责处理并发竞争。
func precheckEduBinding(db *gorm.DB, userID uint, studentID string) error {
	studentID = strings.TrimSpace(studentID)
	var user models.User
	if err := db.Select("id", "student_id", "student_verified_at").First(&user, userID).Error; err != nil {
		return err
	}
	if user.StudentVerifiedAt != nil && user.StudentID != "" && user.StudentID != studentID {
		return errEduStudentIdentityImmutable
	}
	var conflict models.User
	err := db.Select("id").Where("student_id = ? AND id <> ?", studentID, userID).First(&conflict).Error
	if err == nil {
		return errEduStudentAlreadyBound
	}
	if errors.Is(err, gorm.ErrRecordNotFound) {
		return nil
	}
	return err
}

// compensateFailedEduBinding 清理 Python 已落库、但 Go 未能提交身份升级的残留凭据。
func (h *EduHandler) compensateFailedEduBinding(userID uint, generation uint) {
	resp, err := pythonEduRequest(http.MethodDelete, "/api/edu/authorization", &userID, map[string]interface{}{
		"expected_generation": generation,
		"delete_identity":     false,
	})
	if err == nil && resp.StatusCode() == http.StatusOK {
		return
	}
	if h.cleanupJobs == nil || h.db == nil {
		return
	}
	_ = h.db.Transaction(func(tx *gorm.DB) error {
		now := time.Now()
		if err := tx.Model(&models.User{}).Where("id = ?", userID).Updates(map[string]interface{}{
			"edu_authorization_generation":   generation,
			"edu_authorized":                 false,
			"edu_bound":                      false,
			"edu_session_state":              "revoked",
			"edu_auto_relogin":               false,
			"edu_cleanup_pending":            true,
			"edu_binding_state":              "cleanup_pending",
			"edu_binding_pending_generation": 0,
			"edu_binding_pending_student_id": "",
			"edu_binding_started_at":         nil,
			"edu_session_updated_at":         now,
		}).Error; err != nil {
			return err
		}
		return h.cleanupJobs.Enqueue(tx, userID, generation, now, false)
	})
}

func (h *EduHandler) issueBoundEduSession(c *gin.Context, userID uint) {
	var user models.User
	if err := h.db.First(&user, userID).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "刷新账号信息失败"})
		return
	}
	token, err := middleware.GenerateToken(user.ID, string(user.Role), user.TokenVersion, h.jwtSecret)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "无法生成 Token"})
		return
	}
	response, err := selfUserResponseForDB(h.db, user)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "读取账号状态失败"})
		return
	}
	secure := os.Getenv("SSL") == "true" || os.Getenv("ENV") == "production"
	c.SetSameSite(http.SameSiteLaxMode)
	c.SetCookie("jwt", token, 7*24*3600, "/api", "", secure, true)
	c.JSON(http.StatusOK, gin.H{
		"message": "绑定成功，学号已成为主账号，APP 密码保持不变",
		"token":   token,
		"user":    response,
	})
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
	if isStableEduStateErrorCode(svcErr.Code) {
		c.JSON(statusCode, gin.H{"code": svcErr.Code, "error": msg, "upstream_code": svcErr.Code})
		return
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
			"code":          "EDU_BINDING_REJECTED",
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
	StudentID              string `json:"student_id" binding:"required,len=10"`
	Password               string `json:"password" binding:"required"`
	EduDataConsentAccepted bool   `json:"edu_data_consent_accepted"`
}

// BindEdu 绑定教务账号
func (h *EduHandler) BindEdu(c *gin.Context) {
	userID := c.GetUint("user_id")

	var input BindEduInput
	if err := c.ShouldBindJSON(&input); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "参数错误: " + err.Error()})
		return
	}
	if !input.EduDataConsentAccepted {
		c.JSON(http.StatusBadRequest, gin.H{"error": "绑定教务前请阅读并同意教务数据专项授权", "code": "EDU_DATA_CONSENT_REQUIRED"})
		return
	}
	if err := precheckEduBinding(h.db, userID, input.StudentID); err != nil {
		switch {
		case errors.Is(err, errEduStudentAlreadyBound):
			c.JSON(http.StatusConflict, gin.H{"error": "该学号已绑定其他账号", "code": "EDU_STUDENT_ALREADY_BOUND"})
		case errors.Is(err, errEduStudentIdentityImmutable):
			c.JSON(http.StatusConflict, gin.H{"error": "已认证学生不能绑定其他学号", "code": "STUDENT_ID_ALREADY_VERIFIED"})
		default:
			c.JSON(http.StatusInternalServerError, gin.H{"error": "检查学号归属失败"})
		}
		return
	}
	generation, err := prepareEduBinding(h.db, userID, input.StudentID)
	if err != nil {
		if errors.Is(err, errEduBindingStudentMismatch) {
			c.JSON(http.StatusConflict, gin.H{"error": "已有待提交教务绑定，请使用同一学号重试", "code": "EDU_BINDING_PENDING"})
			return
		}
		c.JSON(http.StatusInternalServerError, gin.H{"error": "准备教务授权失败"})
		return
	}

	result, err := bindEduWithPython(userID, input.StudentID, input.Password, generation)
	if err != nil {
		writeEduServiceError(c, err)
		return
	}
	if err := updateUserEduBinding(h.db, userID, input.StudentID, result, generation, true); err != nil {
		h.compensateFailedEduBinding(userID, generation)
		if errors.Is(err, errEduStudentAlreadyBound) {
			c.JSON(http.StatusConflict, gin.H{"error": "该学号已绑定其他账号", "code": "EDU_STUDENT_ALREADY_BOUND"})
			return
		}
		c.JSON(http.StatusInternalServerError, gin.H{"error": "同步教务绑定状态失败"})
		return
	}
	middleware.InvalidateTokenVersionCache(userID)
	h.issueBoundEduSession(c, userID)
}

// UnbindEdu 解绑教务账号
func (h *EduHandler) UnbindEdu(c *gin.Context) {
	// 旧接口在兼容期内映射为撤销授权，不能释放已认证学号。
	h.RevokeEduAuthorization(c)
}

// GetEduStatus 获取教务绑定状态
func (h *EduHandler) GetEduStatus(c *gin.Context) {
	userID := c.GetUint("user_id")
	var localUser models.User
	if err := h.db.First(&localUser, userID).Error; err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "用户不存在"})
		return
	}
	// 用户已撤销授权时，本地状态优先于远端旧副本。只有显式绑定才可恢复授权。
	if !localUser.EduAuthorized && (localUser.EduSessionState == "revoked" || localUser.EduCleanupPending) {
		c.JSON(http.StatusOK, localEduStatusPayload(localUser))
		return
	}
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
	remoteAuthorized := status.Authorized || status.Bound
	if !remoteAuthorized {
		// 远端凭据丢失只能令本地活跃会话降级为过期，不能悄然撤销或重建授权。
		write := h.db.Model(&models.User{}).Where(
			"id = ? AND edu_authorized = ? AND edu_cleanup_pending = ? AND edu_session_state <> ? AND edu_authorization_generation = ?",
			userID, true, false, "revoked", localUser.EduAuthorizationGeneration,
		).Updates(map[string]interface{}{
			"edu_session_state": "expired", "edu_auto_relogin": false, "edu_session_updated_at": time.Now(),
		})
		if write.Error != nil {
			c.JSON(http.StatusInternalServerError, gin.H{"error": "同步教务状态失败"})
			return
		}
		if write.RowsAffected == 0 {
			if err := h.db.First(&localUser, userID).Error; err != nil {
				c.JSON(http.StatusInternalServerError, gin.H{"error": "读取教务状态失败"})
				return
			}
			c.JSON(http.StatusOK, localEduStatusPayload(localUser))
			return
		}
		localUser.EduSessionState = "expired"
		localUser.EduAutoRelogin = false
		c.JSON(http.StatusOK, localEduStatusPayload(localUser))
		return
	}
	updates := map[string]interface{}{
		"edu_session_state":      status.SessionState,
		"edu_auto_relogin":       status.AutoRelogin,
		"edu_session_updated_at": time.Now(),
	}
	if status.StudentID != "" {
		updates["edu_student_id"] = status.StudentID
		updates["edu_grade"] = status.Grade
		updates["edu_college"] = status.College
		updates["edu_major"] = status.Major
	}
	write := h.db.Model(&models.User{}).Where(
		"id = ? AND edu_authorized = ? AND edu_cleanup_pending = ? AND edu_session_state <> ? AND edu_authorization_generation = ?",
		userID, true, false, "revoked", localUser.EduAuthorizationGeneration,
	).Updates(updates)
	if write.Error != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "同步教务状态失败"})
		return
	}
	if write.RowsAffected == 0 {
		if err := h.db.First(&localUser, userID).Error; err != nil {
			c.JSON(http.StatusInternalServerError, gin.H{"error": "读取教务状态失败"})
			return
		}
		c.JSON(http.StatusOK, localEduStatusPayload(localUser))
		return
	}

	c.JSON(http.StatusOK, gin.H{
		"edu_bound":         true,
		"edu_authorized":    true,
		"edu_session_state": status.SessionState,
		"edu_student_id":    status.StudentID,
		"name":              status.Name,
		"edu_grade":         status.Grade,
		"edu_college":       status.College,
		"edu_major":         status.Major,
	})
}

func parseEduSessionResult(resp *resty.Response) (eduSessionResult, error) {
	var result eduSessionResult
	if err := json.Unmarshal(resp.Body(), &result); err != nil || !result.Success {
		if err == nil {
			err = errors.New("教务服务未确认会话操作成功")
		}
		return result, err
	}
	return result, nil
}

func (h *EduHandler) syncEduSessionState(userID uint, result eduSessionResult) (models.User, error) {
	var user models.User
	if err := h.db.First(&user, userID).Error; err != nil {
		return models.User{}, err
	}
	if !user.EduAuthorized || user.EduSessionState == "revoked" || user.EduCleanupPending {
		return user, nil
	}
	now := time.Now()
	sessionState := result.SessionState
	autoRelogin := result.AutoRelogin
	if !result.Authorized {
		// 远端会话信息不能撤销本地授权，只能将当前会话降级为不可用。
		sessionState = "expired"
		autoRelogin = false
	}
	updates := map[string]interface{}{
		"edu_session_state":      sessionState,
		"edu_auto_relogin":       autoRelogin,
		"edu_session_updated_at": now,
		"edu_password":           "",
		"edu_cookie":             "",
	}
	write := h.db.Model(&models.User{}).Where(
		"id = ? AND edu_authorized = ? AND edu_cleanup_pending = ? AND edu_session_state <> ? AND edu_authorization_generation = ?",
		userID, true, false, "revoked", user.EduAuthorizationGeneration,
	).Updates(updates)
	if write.Error != nil {
		return models.User{}, write.Error
	}
	if write.RowsAffected == 0 {
		if err := h.db.First(&user, userID).Error; err != nil {
			return models.User{}, err
		}
		return user, nil
	}
	user.EduSessionState = sessionState
	user.EduAutoRelogin = autoRelogin
	return user, nil
}

// localEduStatusPayload 仅根据本地权威状态构造响应。
// 远端读取与本地撤销并发时，调用方必须返回此状态，不能用旧远端结果覆盖它。
func localEduStatusPayload(user models.User) gin.H {
	state := user.EduSessionState
	if !user.EduAuthorized && (state == "revoked" || user.EduCleanupPending) {
		state = "revoked"
	}
	return gin.H{
		"edu_bound":         user.EduAuthorized,
		"edu_authorized":    user.EduAuthorized,
		"edu_session_state": state,
		"edu_student_id":    user.EduStudentID,
		"edu_grade":         user.EduGrade,
		"edu_college":       user.EduCollege,
		"edu_major":         user.EduMajor,
	}
}

func isStableEduStateErrorCode(code string) bool {
	switch code {
	case "EDU_AUTHORIZATION_REVOKED", "EDU_SESSION_LOGGED_OUT", "EDU_SESSION_EXPIRED", "EDU_CREDENTIAL_UNAVAILABLE":
		return true
	default:
		return false
	}
}

// LogoutEduSession 仅断开教务会话，学生身份和授权凭据仍由服务端保留。
func (h *EduHandler) LogoutEduSession(c *gin.Context) {
	userID := c.GetUint("user_id")
	resp, err := pythonEduRequest(http.MethodPost, "/api/edu/session/logout", &userID, nil)
	if err != nil {
		writeEduServiceError(c, &eduServiceRequestError{err: err})
		return
	}
	if resp.StatusCode() != http.StatusOK {
		mapEduServiceError(c, resp.StatusCode(), resp.Body())
		return
	}
	result, err := parseEduSessionResult(resp)
	if err != nil {
		c.JSON(http.StatusBadGateway, gin.H{"error": "教务服务返回异常"})
		return
	}
	user, err := h.syncEduSessionState(userID, result)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "同步教务会话状态失败"})
		return
	}
	_ = h.db.Create(&models.AccountSecurityAuditLog{UserID: userID, Action: "edu_session_logged_out"}).Error
	c.JSON(http.StatusOK, gin.H{"message": result.Message, "edu_authorized": user.EduAuthorized, "edu_session_state": user.EduSessionState})
}

// ResumeEduSession 仅在用户明确点击后恢复会话，绝不由客户端静默触发。
func (h *EduHandler) ResumeEduSession(c *gin.Context) {
	userID := c.GetUint("user_id")
	resp, err := pythonEduRequest(http.MethodPost, "/api/edu/session/resume", &userID, nil)
	if err != nil {
		writeEduServiceError(c, &eduServiceRequestError{err: err})
		return
	}
	if resp.StatusCode() != http.StatusOK {
		mapEduServiceError(c, resp.StatusCode(), resp.Body())
		return
	}
	result, err := parseEduSessionResult(resp)
	if err != nil {
		c.JSON(http.StatusBadGateway, gin.H{"error": "教务服务返回异常"})
		return
	}
	user, err := h.syncEduSessionState(userID, result)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "同步教务会话状态失败"})
		return
	}
	_ = h.db.Create(&models.AccountSecurityAuditLog{UserID: userID, Action: "edu_session_resumed"}).Error
	c.JSON(http.StatusOK, gin.H{"message": result.Message, "edu_authorized": user.EduAuthorized, "edu_session_state": user.EduSessionState})
}

// RevokeEduAuthorization 撤销凭据使用权；稳定学号、学生认证和基础资料均不受影响。
func (h *EduHandler) RevokeEduAuthorization(c *gin.Context) {
	userID := c.GetUint("user_id")
	now := time.Now()
	var generation uint
	if err := h.db.Transaction(func(tx *gorm.DB) error {
		var user models.User
		if err := tx.Clauses(clause.Locking{Strength: "UPDATE"}).First(&user, userID).Error; err != nil {
			return err
		}
		generation = user.EduAuthorizationGeneration
		updates := map[string]interface{}{
			"edu_authorized": false, "edu_bound": false, "edu_session_state": "revoked",
			"edu_auto_relogin": false, "edu_session_updated_at": now,
			"edu_cleanup_pending": true, "edu_password": "", "edu_cookie": "",
			"edu_binding_state": "cleanup_pending", "edu_binding_pending_generation": 0, "edu_binding_pending_student_id": "", "edu_binding_started_at": nil,
		}
		if err := tx.Model(&models.User{}).Where("id = ?", userID).Updates(updates).Error; err != nil {
			return err
		}
		if err := tx.Model(&models.UserLegalConsent{}).
			Where("user_id = ? AND document = ? AND revoked_at IS NULL", userID, models.LegalDocumentEduDataConsent).
			Update("revoked_at", now).Error; err != nil {
			return err
		}
		if h.cleanupJobs != nil {
			return h.cleanupJobs.Enqueue(tx, userID, generation, now, false)
		}
		return nil
	}); err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "撤销教务授权失败"})
		return
	}

	// 本地状态已先提交；远端暂时不可用时由 outbox 后台重试，避免用户无法撤销授权。
	resp, err := pythonEduRequest(http.MethodDelete, "/api/edu/authorization", &userID, map[string]interface{}{
		"expected_generation": generation,
		"delete_identity":     false,
	})
	if err != nil || resp.StatusCode() != http.StatusOK {
		_ = h.db.Create(&models.AccountSecurityAuditLog{UserID: userID, Action: "edu_authorization_revoked_pending_cleanup"}).Error
		c.JSON(http.StatusAccepted, gin.H{"message": "教务授权已撤销，凭据清理将在后台完成", "edu_authorized": false, "edu_session_state": "revoked"})
		return
	}
	if h.cleanupJobs != nil {
		if err := h.cleanupJobs.CompleteGeneration(c.Request.Context(), userID, generation, false); err != nil {
			c.JSON(http.StatusInternalServerError, gin.H{"error": "同步凭据清理状态失败"})
			return
		}
	}
	_ = h.db.Create(&models.AccountSecurityAuditLog{UserID: userID, Action: "edu_authorization_revoked"}).Error
	c.JSON(http.StatusOK, gin.H{"message": "教务授权已撤销", "edu_authorized": false, "edu_session_state": "revoked"})
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
	var input CourseInput
	if err := c.ShouldBindJSON(&input); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
		return
	}
	h.fetchAcademicDataset(c, services.EduFetchRequest{
		Dataset: academic.DatasetSchedule, Year: input.Year, Semester: input.Semester,
		CurrentTerm: true, ForceRefresh: true,
	})
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

// GetGrades 获取成绩（通过Python服务访问教务系统）
func (h *EduHandler) GetGrades(c *gin.Context) {
	var input GradesInput
	if err := c.ShouldBindJSON(&input); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
		return
	}
	h.fetchAcademicDataset(c, services.EduFetchRequest{
		Dataset: academic.DatasetGrades, Year: input.Year, Semester: input.Semester, ForceRefresh: true,
	})
}

// GetAcademicSituation 获取官方学生学业情况（通过Python服务访问教务系统）
func (h *EduHandler) GetAcademicSituation(c *gin.Context) {
	h.fetchAcademicDataset(c, services.EduFetchRequest{
		Dataset: academic.DatasetAcademicSituation, ForceRefresh: true,
	})
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

// GetCreditRequirements 获取官方学分要求/学籍预警数据（通过Python服务访问教务系统）
func (h *EduHandler) GetCreditRequirements(c *gin.Context) {
	h.fetchAcademicDataset(c, services.EduFetchRequest{
		Dataset: academic.DatasetCreditRequirements, ForceRefresh: true,
	})
}

// fetchAcademicDataset 维持既有客户端业务 JSON 兼容性，来源和过期元数据由编排层供 MCP 使用。
func (h *EduHandler) fetchAcademicDataset(c *gin.Context, request services.EduFetchRequest) {
	if h.academicFetcher == nil {
		c.JSON(http.StatusServiceUnavailable, gin.H{"error": "学业快照服务暂未配置"})
		return
	}
	result, err := h.academicFetcher.Fetch(c.Request.Context(), c.GetUint("user_id"), request)
	if err != nil {
		c.JSON(http.StatusBadGateway, gin.H{"error": "教务数据请求失败，请稍后再试"})
		return
	}
	switch result.Status {
	case academic.DataStatusAvailable, academic.DataStatusStale, academic.DataStatusPartial:
		// 只有实际远程拉取并成功写入快照后，才可以继续等待授权的 Agent 推理。
		// 缓存命中或旧快照回退不能错误地解除授权等待。
		if result.Source == academic.DataSourceRemoteEduFetch && h.runResumer != nil {
			_ = h.runResumer.ResumeUserConsent(c.Request.Context(), c.GetUint("user_id"))
		}
		c.Data(http.StatusOK, "application/json; charset=utf-8", result.Data)
	case academic.DataStatusPermissionRequired:
		c.JSON(http.StatusConflict, gin.H{"code": "EDU_AUTHORIZATION_REQUIRED", "error": "教务授权已失效，请重新授权"})
	default:
		message := "教务数据暂时无法更新，请稍后再试"
		if len(result.Warnings) > 0 {
			message = result.Warnings[0]
		}
		c.JSON(http.StatusBadGateway, gin.H{"error": message})
	}
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
	if statusCode >= http.StatusInternalServerError || statusCode == 0 {
		return &eduLoginError{Code: "REMOTE_SYSTEM_UNAVAILABLE", Message: "学校教务系统暂时不可用，请稍后再试"}
	}
	return &eduLoginError{Code: "CAS_FLOW_CHANGED", Message: "学校登录页面可能发生变化，请稍后重试或联系管理员"}
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
	Name        string   `json:"name"`
	ClassID     string   `json:"class_id"`
	Teacher     string   `json:"teacher"`
	IsDegree    bool     `json:"is_degree"`
	Credits     float64  `json:"credits"`
	GPA         *float64 `json:"gpa,omitempty"`
	GradePoints *float64 `json:"grade_points,omitempty"`
	Fraction    *float64 `json:"fraction,omitempty"`
	Grade       string   `json:"grade"`
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
		grade.GPA = optionalGradeNumber(v.Jd)
		grade.GradePoints = optionalGradeNumber(v.Xfjd)
		grade.Fraction = optionalGradeNumber(v.Bfzcj)
		grade.Grade = v.Cj
		result = append(result, grade)
	}

	return result, nil
}

func optionalGradeNumber(value string) *float64 {
	number, err := strconv.ParseFloat(strings.TrimSpace(value), 64)
	if err != nil {
		return nil
	}
	return &number
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
