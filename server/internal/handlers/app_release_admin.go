package handlers

import (
	"context"
	"errors"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/gin-gonic/gin"
	"gorm.io/gorm"

	"shenliyuan/internal/models"
	"shenliyuan/internal/services"
)

// AdminList 返回全部 APK 版本，供超级管理员核对草稿、发布和下架状态。
func (h *AppUpdateHandler) AdminList(c *gin.Context) {
	status := strings.TrimSpace(c.Query("status"))
	query := h.svc.DB().Model(&models.AppRelease{})
	if status != "" {
		if status != models.AppReleaseStatusDraft && status != models.AppReleaseStatusPublished && status != models.AppReleaseStatusWithdrawn {
			c.JSON(http.StatusBadRequest, gin.H{"error": "无效的版本状态", "code": "invalid_release_status"})
			return
		}
		query = query.Where("status = ?", status)
	}
	var releases []models.AppRelease
	if err := query.Order("version_code DESC, id DESC").Find(&releases).Error; err != nil {
		c.JSON(http.StatusServiceUnavailable, gin.H{"error": "读取应用版本失败", "code": "app_release_list_failed"})
		return
	}
	c.JSON(http.StatusOK, gin.H{"items": releases})
}

// AdminGet 返回单个 APK 版本的完整元数据。
func (h *AppUpdateHandler) AdminGet(c *gin.Context) {
	id, ok := parseAppReleaseID(c)
	if !ok {
		return
	}
	var release models.AppRelease
	if err := h.svc.DB().First(&release, id).Error; err != nil {
		writeAdminReleaseError(c, err, "读取应用版本失败")
		return
	}
	c.JSON(http.StatusOK, release)
}

// AdminCreate 上传并创建 APK 草稿。发布由独立接口完成，避免半包被客户端下载。
func (h *AppUpdateHandler) AdminCreate(c *gin.Context) {
	maxSize := h.svc.MaxSize()
	c.Request.Body = http.MaxBytesReader(c.Writer, c.Request.Body, maxSize+1024*1024)
	if err := c.Request.ParseMultipartForm(maxSize + 1024*1024); err != nil {
		c.JSON(http.StatusRequestEntityTooLarge, gin.H{"error": "APK 上传体积超过限制", "code": "apk_too_large"})
		return
	}
	fileHeader, err := c.FormFile("apk")
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "缺少 APK 文件", "code": "missing_apk"})
		return
	}
	file, err := fileHeader.Open()
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "读取 APK 文件失败", "code": "apk_open_failed"})
		return
	}
	defer file.Close()
	versionCode, err := parsePositiveInt64(c.PostForm("version_code"))
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "version_code 必须为正整数", "code": "invalid_version_code"})
		return
	}
	minimum, err := parsePositiveInt64(c.PostForm("minimum_supported_version_code"))
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "minimum_supported_version_code 必须为正整数", "code": "invalid_minimum_supported_version_code"})
		return
	}
	ctx, cancel := context.WithTimeout(c.Request.Context(), 3*time.Minute)
	defer cancel()
	release, err := h.svc.CreateDraft(ctx, services.AppReleaseDraftInput{
		Platform:                    c.DefaultPostForm("platform", models.AppReleasePlatformAndroid),
		Channel:                     c.DefaultPostForm("channel", models.AppReleaseChannelStable),
		VersionName:                 c.PostForm("version_name"),
		VersionCode:                 versionCode,
		Title:                       c.PostForm("title"),
		Changelog:                   c.PostForm("changelog"),
		MinimumSupportedVersionCode: minimum,
		CreatedBy:                   c.GetUint("user_id"),
	}, fileHeader.Filename, file, maxSize)
	if err != nil {
		writeAdminReleaseError(c, err, "创建应用版本草稿失败")
		return
	}
	c.JSON(http.StatusCreated, release)
}

type updateAppReleaseInput struct {
	Title                       *string `json:"title"`
	Changelog                   *string `json:"changelog"`
	MinimumSupportedVersionCode *int64  `json:"minimum_supported_version_code"`
}

// AdminUpdate 修改草稿内容，或调整当前最高已发布版本的最低支持构建号。
func (h *AppUpdateHandler) AdminUpdate(c *gin.Context) {
	id, ok := parseAppReleaseID(c)
	if !ok {
		return
	}
	var input updateAppReleaseInput
	if err := c.ShouldBindJSON(&input); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "更新版本参数无效", "code": "invalid_release_update"})
		return
	}
	updated, err := h.svc.UpdateDraft(c.Request.Context(), id, c.GetUint("user_id"), services.AppReleaseDraftUpdate{
		Title: input.Title, Changelog: input.Changelog, MinimumSupportedVersionCode: input.MinimumSupportedVersionCode,
	})
	if err != nil {
		writeAdminReleaseError(c, err, "更新应用版本草稿失败")
		return
	}
	c.JSON(http.StatusOK, updated)
}

// AdminPublish 使草稿成为新的可下载版本。
func (h *AppUpdateHandler) AdminPublish(c *gin.Context) {
	id, ok := parseAppReleaseID(c)
	if !ok {
		return
	}
	release, err := h.svc.PublishDraft(c.Request.Context(), id, c.GetUint("user_id"))
	if err != nil {
		writeAdminReleaseError(c, err, "发布应用版本失败")
		return
	}
	c.JSON(http.StatusOK, release)
}

// AdminWithdraw 停止新下载但保留 APK 文件和审计数据。
func (h *AppUpdateHandler) AdminWithdraw(c *gin.Context) {
	id, ok := parseAppReleaseID(c)
	if !ok {
		return
	}
	release, err := h.svc.WithdrawPublished(c.Request.Context(), id, c.GetUint("user_id"))
	if err != nil {
		writeAdminReleaseError(c, err, "下架应用版本失败")
		return
	}
	c.JSON(http.StatusOK, release)
}

// AdminDeleteDraft 只能删除从未发布过的草稿与其私有 APK 文件。
func (h *AppUpdateHandler) AdminDeleteDraft(c *gin.Context) {
	id, ok := parseAppReleaseID(c)
	if !ok {
		return
	}
	if err := h.svc.DeleteDraft(c.Request.Context(), id, c.GetUint("user_id")); err != nil {
		writeAdminReleaseError(c, err, "删除应用版本草稿失败")
		return
	}
	c.Status(http.StatusNoContent)
}

func parseAppReleaseID(c *gin.Context) (uint, bool) {
	value, err := strconv.ParseUint(c.Param("id"), 10, 64)
	if err != nil || value == 0 {
		c.JSON(http.StatusBadRequest, gin.H{"error": "无效的应用版本 ID", "code": "invalid_release_id"})
		return 0, false
	}
	return uint(value), true
}

func parsePositiveInt64(raw string) (int64, error) {
	value, err := strconv.ParseInt(strings.TrimSpace(raw), 10, 64)
	if err != nil || value <= 0 {
		return 0, errors.New("必须为正整数")
	}
	return value, nil
}

func writeAdminReleaseError(c *gin.Context, err error, fallback string) {
	switch {
	case errors.Is(err, services.ErrAppReleaseNotFound), errors.Is(err, gorm.ErrRecordNotFound):
		c.JSON(http.StatusNotFound, gin.H{"error": "应用版本不存在", "code": "release_not_found"})
	case errors.Is(err, services.ErrAppReleaseInvalid):
		c.JSON(http.StatusBadRequest, gin.H{"error": err.Error(), "code": "invalid_app_release"})
	case errors.Is(err, services.ErrAppReleaseNotDraft), errors.Is(err, services.ErrAppReleaseNotPublished), errors.Is(err, services.ErrAppReleaseNoFallback):
		c.JSON(http.StatusConflict, gin.H{"error": err.Error(), "code": "invalid_release_state"})
	default:
		c.JSON(http.StatusServiceUnavailable, gin.H{"error": fallback, "code": "app_release_operation_failed"})
	}
}
