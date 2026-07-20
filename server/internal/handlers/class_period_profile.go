package handlers

import (
	"encoding/json"
	"errors"
	"net/http"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/gin-gonic/gin"
	"gorm.io/datatypes"
	"gorm.io/gorm"

	"shenliyuan/internal/academiccalendar"
	"shenliyuan/internal/models"
)

var classPeriodAcademicYearPattern = regexp.MustCompile(`^\d{4}-\d{4}$`)

type ClassPeriodProfileHandler struct{ db *gorm.DB }

func NewClassPeriodProfileHandler(db *gorm.DB) *ClassPeriodProfileHandler {
	return &ClassPeriodProfileHandler{db: db}
}

type classPeriodInput struct {
	Section   int    `json:"section"`
	StartTime string `json:"start_time"`
	EndTime   string `json:"end_time"`
}

type classPeriodProfileRequest struct {
	AcademicYear  string             `json:"academic_year"`
	Name          string             `json:"name"`
	EffectiveFrom string             `json:"effective_from"`
	EffectiveTo   string             `json:"effective_to"`
	Periods       []classPeriodInput `json:"periods"`
}

func (h *ClassPeriodProfileHandler) Create(c *gin.Context) {
	var request classPeriodProfileRequest
	if err := decodeStrictJSON(c, &request, 64<<10); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"code": "invalid_request", "message": "节次配置格式错误"})
		return
	}
	if err := validateClassPeriodProfile(&request); err != nil {
		c.JSON(http.StatusUnprocessableEntity, gin.H{"code": "class_period_profile_invalid", "message": err.Error()})
		return
	}
	from, _ := time.ParseInLocation("2006-01-02", request.EffectiveFrom, academiccalendar.ShanghaiLocation)
	to, _ := time.ParseInLocation("2006-01-02", request.EffectiveTo, academiccalendar.ShanghaiLocation)
	to = to.Add(24*time.Hour - time.Nanosecond)
	periods, _ := json.Marshal(request.Periods)
	profile := models.ClassPeriodProfile{
		AcademicYear: request.AcademicYear, Name: strings.TrimSpace(request.Name), Status: "draft",
		Periods: datatypes.JSON(periods), EffectiveFrom: from, EffectiveTo: to, CreatedBy: c.GetUint("user_id"),
	}
	if err := h.db.WithContext(c.Request.Context()).Create(&profile).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"code": "class_period_profile_create_failed", "message": "创建节次配置失败"})
		return
	}
	c.JSON(http.StatusCreated, gin.H{"profile": profile})
}

func (h *ClassPeriodProfileHandler) List(c *gin.Context) {
	var profiles []models.ClassPeriodProfile
	query := h.db.WithContext(c.Request.Context()).Order("id DESC").Limit(100)
	if year := strings.TrimSpace(c.Query("academic_year")); year != "" {
		query = query.Where("academic_year = ?", year)
	}
	if err := query.Find(&profiles).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"code": "class_period_profile_list_failed", "message": "读取节次配置失败"})
		return
	}
	c.JSON(http.StatusOK, gin.H{"profiles": profiles})
}

func (h *ClassPeriodProfileHandler) Publish(c *gin.Context) {
	if !requireKnowledgePublishPermission(c) || !requireEmptyKnowledgeActionBody(c) {
		return
	}
	id, err := strconv.ParseUint(c.Param("id"), 10, 64)
	if err != nil || id == 0 {
		c.JSON(http.StatusBadRequest, gin.H{"code": "invalid_profile_id", "message": "节次配置 ID 无效"})
		return
	}
	var profile models.ClassPeriodProfile
	err = h.db.WithContext(c.Request.Context()).Transaction(func(tx *gorm.DB) error {
		if err := tx.First(&profile, uint(id)).Error; err != nil {
			return err
		}
		if profile.Status != "draft" {
			return errors.New("class period profile is not draft")
		}
		if err := tx.Model(&models.ClassPeriodProfile{}).
			Where("academic_year = ? AND status = ? AND id <> ?", profile.AcademicYear, "published", profile.ID).
			Update("status", "archived").Error; err != nil {
			return err
		}
		now := time.Now()
		return tx.Model(&profile).Updates(map[string]interface{}{
			"status": "published", "published_by": c.GetUint("user_id"), "published_at": now,
		}).Error
	})
	if errors.Is(err, gorm.ErrRecordNotFound) {
		c.JSON(http.StatusNotFound, gin.H{"code": "class_period_profile_not_found", "message": "节次配置不存在"})
		return
	}
	if err != nil {
		c.JSON(http.StatusConflict, gin.H{"code": "class_period_profile_publish_failed", "message": "发布节次配置失败"})
		return
	}
	c.JSON(http.StatusOK, gin.H{"profile": profile})
}

func validateClassPeriodProfile(request *classPeriodProfileRequest) error {
	if academiccalendar.ShanghaiLocation == nil {
		return errors.New("Asia/Shanghai 时区不可用")
	}
	request.AcademicYear = strings.TrimSpace(request.AcademicYear)
	request.Name = strings.TrimSpace(request.Name)
	if !classPeriodAcademicYearPattern.MatchString(request.AcademicYear) || request.Name == "" || len(request.Periods) == 0 || len(request.Periods) > 30 {
		return errors.New("学年、名称或节次数量无效")
	}
	from, err := time.ParseInLocation("2006-01-02", request.EffectiveFrom, academiccalendar.ShanghaiLocation)
	if err != nil {
		return errors.New("生效日期格式无效")
	}
	to, err := time.ParseInLocation("2006-01-02", request.EffectiveTo, academiccalendar.ShanghaiLocation)
	if err != nil || to.Before(from) {
		return errors.New("失效日期格式或范围无效")
	}
	sort.Slice(request.Periods, func(i, j int) bool { return request.Periods[i].Section < request.Periods[j].Section })
	previousSection, previousEnd := 0, 0
	for _, period := range request.Periods {
		start, startErr := time.Parse("15:04", period.StartTime)
		end, endErr := time.Parse("15:04", period.EndTime)
		startMinutes, endMinutes := start.Hour()*60+start.Minute(), end.Hour()*60+end.Minute()
		if period.Section <= previousSection || startErr != nil || endErr != nil || endMinutes <= startMinutes || startMinutes < previousEnd {
			return errors.New("节次编号或时间范围无效、重复或重叠")
		}
		previousSection, previousEnd = period.Section, endMinutes
	}
	return nil
}
