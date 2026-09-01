package handlers

import (
	"context"
	"encoding/json"
	"errors"
	"log"
	"net/http"
	"strings"

	"github.com/gin-gonic/gin"

	"shenliyuan/internal/middleware"
	"shenliyuan/internal/services"
)

// DeviceJobHandler 为已认证的 Flutter 安装实例提供设备任务协议。
// 所有作业接口都以 JWT user_id 和 X-Device-Installation-ID 双重鉴权。
type DeviceJobHandler struct {
	service          *services.DeviceJobService
	resumer          DeviceJobRunResumer
	progressReporter DeviceJobActivityReporter
}

// DeviceJobRunResumer 隔离 Handler 与 AI Runtime，设备协议不依赖具体模型实现。
type DeviceJobRunResumer interface {
	ResumeDeviceJob(context.Context, string) error
}

type DeviceJobActivityReporter interface {
	PublishDeviceJobProgress(context.Context, string, string) error
}

func NewDeviceJobHandler(service *services.DeviceJobService) *DeviceJobHandler {
	return &DeviceJobHandler{service: service}
}

// SetRunResumer 在 AI Runtime 初始化完成后接入回调；未启用 AI 时设备任务接口仍可独立使用。
func (h *DeviceJobHandler) SetRunResumer(resumer DeviceJobRunResumer) {
	h.resumer = resumer
	if reporter, ok := resumer.(DeviceJobActivityReporter); ok {
		h.progressReporter = reporter
	}
}

type deviceRegistrationRequest struct {
	InstallationID        string   `json:"installation_id"`
	PushToken             string   `json:"push_token"`
	ToolNames             []string `json:"tool_names"`
	BridgeProtocolVersion int      `json:"bridge_protocol_version"`
	ClientVersion         string   `json:"client_version"`
}

// Register 的请求与响应均不携带个人快照；push_token 只用于后续发送 job_id 通知。
func (h *DeviceJobHandler) Register(c *gin.Context) {
	var request deviceRegistrationRequest
	if err := decodeStrictJSON(c, &request, 8<<10); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"code": "invalid_device_registration", "message": "设备登记请求无效"})
		return
	}
	device, err := h.service.RegisterDevice(c.Request.Context(), c.GetUint("user_id"), services.DeviceRegistration{
		InstallationID: request.InstallationID, PushToken: request.PushToken, ToolNames: request.ToolNames,
		BridgeProtocolVersion: request.BridgeProtocolVersion, ClientVersion: request.ClientVersion,
	})
	if err != nil {
		writeDeviceJobError(c, err)
		return
	}
	c.JSON(http.StatusOK, gin.H{"device": device})
}

func (h *DeviceJobHandler) Pending(c *gin.Context) {
	jobs, err := h.service.PendingJobs(c.Request.Context(), c.GetUint("user_id"), deviceInstallationID(c))
	if err != nil {
		writeDeviceJobError(c, err)
		return
	}
	c.JSON(http.StatusOK, gin.H{"jobs": jobs})
}

func (h *DeviceJobHandler) Get(c *gin.Context) {
	job, err := h.service.GetJob(c.Request.Context(), c.GetUint("user_id"), deviceInstallationID(c), c.Param("id"))
	if err != nil {
		writeDeviceJobError(c, err)
		return
	}
	c.JSON(http.StatusOK, gin.H{"job": job})
}

type deviceJobStateRequest struct {
	StateVersion int64 `json:"state_version"`
}

type deviceJobProgressRequest struct {
	StateVersion int64  `json:"state_version"`
	Stage        string `json:"stage"`
}

func (h *DeviceJobHandler) Progress(c *gin.Context) {
	var request deviceJobProgressRequest
	if err := decodeStrictJSON(c, &request, 2<<10); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"code": "invalid_progress_stage", "message": "设备进度无效"})
		return
	}
	job, err := h.service.ProgressJob(c.Request.Context(), c.GetUint("user_id"), deviceInstallationID(c), c.Param("id"), request.StateVersion, request.Stage)
	if err != nil {
		writeDeviceJobError(c, err)
		return
	}
	if h.progressReporter != nil {
		_ = h.progressReporter.PublishDeviceJobProgress(c.Request.Context(), job.ID, request.Stage)
	}
	if job.Status == "failed" && h.resumer != nil {
		h.resumeDeviceJobAsync(job.ID, middleware.DetachedRequestContext(c.Request.Context()))
	}
	c.JSON(http.StatusOK, gin.H{"job": job})
}

func (h *DeviceJobHandler) Claim(c *gin.Context) {
	var request deviceJobStateRequest
	if err := decodeStrictJSON(c, &request, 4<<10); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"code": "invalid_request", "message": "领取请求无效"})
		return
	}
	job, err := h.service.ClaimJob(c.Request.Context(), c.GetUint("user_id"), deviceInstallationID(c), c.Param("id"), request.StateVersion)
	if err != nil {
		writeDeviceJobError(c, err)
		return
	}
	c.JSON(http.StatusOK, gin.H{"job": job})
}

// WaitForUser 记录设备任务进入等待用户凭据状态；不触发 Run resume，
// 由用户完成凭据输入后的 Complete/Fail 流程继续驱动。
func (h *DeviceJobHandler) WaitForUser(c *gin.Context) {
	var request deviceJobStateRequest
	if err := decodeStrictJSON(c, &request, 4<<10); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"code": "invalid_request", "message": "等待请求无效"})
		return
	}
	job, err := h.service.WaitForUserJob(c.Request.Context(), c.GetUint("user_id"), deviceInstallationID(c), c.Param("id"), request.StateVersion)
	if err != nil {
		writeDeviceJobError(c, err)
		return
	}
	c.JSON(http.StatusOK, gin.H{"job": job})
}

type deviceJobCompleteRequest struct {
	StateVersion int64           `json:"state_version"`
	Result       json.RawMessage `json:"result"`
}

func (h *DeviceJobHandler) Complete(c *gin.Context) {
	var request deviceJobCompleteRequest
	if err := decodeStrictJSON(c, &request, 260<<10); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"code": "invalid_request", "message": "完成请求无效"})
		return
	}
	job, err := h.service.CompleteJob(c.Request.Context(), c.GetUint("user_id"), deviceInstallationID(c), c.Param("id"), request.StateVersion, request.Result)
	if err != nil {
		writeDeviceJobError(c, err)
		return
	}
	if h.resumer != nil {
		h.resumeDeviceJobAsync(job.ID, middleware.DetachedRequestContext(c.Request.Context()))
	}
	c.JSON(http.StatusOK, gin.H{"job": job})
}

type deviceJobFailRequest struct {
	StateVersion int64  `json:"state_version"`
	ErrorCode    string `json:"error_code"`
}

func (h *DeviceJobHandler) Fail(c *gin.Context) {
	var request deviceJobFailRequest
	if err := decodeStrictJSON(c, &request, 4<<10); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"code": "invalid_request", "message": "失败请求无效"})
		return
	}
	job, err := h.service.FailJob(c.Request.Context(), c.GetUint("user_id"), deviceInstallationID(c), c.Param("id"), request.StateVersion, request.ErrorCode)
	if err != nil {
		writeDeviceJobError(c, err)
		return
	}
	if h.resumer != nil {
		h.resumeDeviceJobAsync(job.ID, middleware.DetachedRequestContext(c.Request.Context()))
	}
	c.JSON(http.StatusOK, gin.H{"job": job})
}

func (h *DeviceJobHandler) Cancel(c *gin.Context) {
	var request deviceJobStateRequest
	if err := decodeStrictJSON(c, &request, 4<<10); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"code": "invalid_request", "message": "取消请求无效"})
		return
	}
	job, err := h.service.CancelJob(c.Request.Context(), c.GetUint("user_id"), deviceInstallationID(c), c.Param("id"), request.StateVersion)
	if err != nil {
		writeDeviceJobError(c, err)
		return
	}
	if h.resumer != nil {
		h.resumeDeviceJobAsync(job.ID, middleware.DetachedRequestContext(c.Request.Context()))
	}
	c.JSON(http.StatusOK, gin.H{"job": job})
}

func (h *DeviceJobHandler) resumeDeviceJobAsync(jobID string, ctx context.Context) {
	go func() {
		if err := h.resumer.ResumeDeviceJob(ctx, jobID); err != nil {
			// 设备任务已经完成，不能把 HTTP 响应改成 500；记录错误交给
			// Runtime 的 reconciler 继续恢复，避免客户端重复提交同一结果。
			log.Printf("[AI_DEVICE_RESUME_FAILED] job_id=%s err=%v", jobID, err)
		}
	}()
}

func deviceInstallationID(c *gin.Context) string {
	return strings.TrimSpace(c.GetHeader("X-Device-Installation-ID"))
}

func writeDeviceJobError(c *gin.Context, err error) {
	var deviceErr *services.DeviceJobError
	if !errors.As(err, &deviceErr) {
		c.JSON(http.StatusInternalServerError, gin.H{"code": "device_job_unavailable", "message": "设备任务服务暂时不可用"})
		return
	}
	status := http.StatusConflict
	message := "设备任务状态已变化"
	switch deviceErr.Code {
	case "unauthorized":
		status, message = http.StatusUnauthorized, "登录状态无效"
	case "device_not_registered":
		status, message = http.StatusForbidden, "当前设备未登记或不属于此账号"
	case "device_job_not_found":
		status, message = http.StatusNotFound, "设备任务不存在"
	case "job_expired":
		status, message = http.StatusGone, "设备任务已过期"
	case "school_device_capability_retired":
		status, message = http.StatusGone, "学校设备能力已退役"
	case "invalid_device_registration", "invalid_device_job", "invalid_tool_arguments", "invalid_tool_result", "invalid_state_version", "invalid_error_code", "invalid_job_expiry", "invalid_progress_stage":
		status, message = http.StatusBadRequest, "设备任务请求无效"
	case "tool_not_allowed":
		status, message = http.StatusForbidden, "设备工具不在允许列表中"
	case "device_offline":
		status, message = http.StatusConflict, "没有可用的已登记设备"
	case "device_client_outdated":
		status, message = http.StatusConflict, "设备客户端版本过低，请升级后重试"
	case "state_version_conflict", "invalid_job_state":
		status, message = http.StatusConflict, "设备任务状态已变化"
	}
	c.JSON(status, gin.H{"code": deviceErr.Code, "message": message})
}
