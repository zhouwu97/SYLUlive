package handlers

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/gin-gonic/gin"
	"gorm.io/datatypes"
	"gorm.io/gorm"

	"shenliyuan/internal/models"
)

const calendarDateLayout = "2006-01-02"

var academicYearPattern = regexp.MustCompile(`^\d{4}-\d{4}$`)

// CampusCalendarHandler 管理校历的查询、校验和版本发布。
type CampusCalendarHandler struct {
	db *gorm.DB
}

func NewCampusCalendarHandler(db *gorm.DB) *CampusCalendarHandler {
	return &CampusCalendarHandler{db: db}
}

type campusCalendarDocument struct {
	SchemaVersion int    `json:"schema_version"`
	CalendarID    string `json:"calendar_id"`
	School        string `json:"school"`
	AcademicYear  string `json:"academic_year"`
	Timezone      string `json:"timezone"`
	Source        struct {
		Type     string `json:"type"`
		Title    string `json:"title"`
		FileName string `json:"file_name"`
		Verified bool   `json:"verified"`
	} `json:"source"`
	Semesters []campusSemesterDocument `json:"semesters"`
	Events    []campusEventDocument    `json:"events"`
	Overrides []campusOverrideDocument `json:"day_overrides"`
}

type campusSemesterDocument struct {
	ID            string                       `json:"id"`
	Name          string                       `json:"name"`
	StartDate     string                       `json:"start_date"`
	EndDate       string                       `json:"end_date"`
	TeachingWeeks []campusTeachingWeekDocument `json:"teaching_weeks"`
}

type campusTeachingWeekDocument struct {
	Week      int    `json:"week"`
	StartDate string `json:"start_date"`
	EndDate   string `json:"end_date"`
}

type campusEventDocument struct {
	ID        string `json:"id"`
	Title     string `json:"title"`
	Type      string `json:"type"`
	StartDate string `json:"start_date"`
	EndDate   string `json:"end_date"`
}

type campusOverrideDocument struct {
	Date    string `json:"date"`
	DayMode string `json:"day_mode"`
}

type calendarValidationIssue struct {
	Path    string `json:"path"`
	Message string `json:"message"`
}

type calendarValidationResult struct {
	Valid    bool                      `json:"valid"`
	Errors   []calendarValidationIssue `json:"errors"`
	Warnings []calendarValidationIssue `json:"warnings"`
}

// GetCurrent 返回当前已发布校历。没有数据时返回 404，客户端可回退到本地内置版本。
func (h *CampusCalendarHandler) GetCurrent(c *gin.Context) {
	var calendar models.CampusCalendar
	if err := h.db.Where("status = ?", "published").Order("published_at DESC, id DESC").First(&calendar).Error; err != nil {
		if err == gorm.ErrRecordNotFound {
			c.JSON(http.StatusNotFound, gin.H{"error": "暂无已发布校历"})
			return
		}
		c.JSON(http.StatusInternalServerError, gin.H{"error": "获取校历失败"})
		return
	}
	h.writeCalendar(c, calendar)
}

// GetByAcademicYear 返回指定学年的已发布校历。
func (h *CampusCalendarHandler) GetByAcademicYear(c *gin.Context) {
	year := strings.TrimSpace(c.Param("academic_year"))
	if !academicYearPattern.MatchString(year) {
		c.JSON(http.StatusBadRequest, gin.H{"error": "学年格式应为 YYYY-YYYY"})
		return
	}

	var calendar models.CampusCalendar
	if err := h.db.Where("academic_year = ? AND status = ?", year, "published").First(&calendar).Error; err != nil {
		if err == gorm.ErrRecordNotFound {
			c.JSON(http.StatusNotFound, gin.H{"error": "该学年暂无已发布校历"})
			return
		}
		c.JSON(http.StatusInternalServerError, gin.H{"error": "获取校历失败"})
		return
	}
	h.writeCalendar(c, calendar)
}

// Preview 校验管理员待导入的 JSON，但不保存草稿。
func (h *CampusCalendarHandler) Preview(c *gin.Context) {
	raw, document, result, ok := readAndValidateCalendar(c)
	_ = raw
	_ = document
	if !ok {
		return
	}
	c.JSON(http.StatusOK, result)
}

// CreateDraft 为合法 JSON 创建一个递增版本的草稿。
func (h *CampusCalendarHandler) CreateDraft(c *gin.Context) {
	raw, document, result, ok := readAndValidateCalendar(c)
	if !ok {
		return
	}
	if !result.Valid {
		c.JSON(http.StatusUnprocessableEntity, result)
		return
	}

	userID := c.GetUint("user_id")
	var created models.CampusCalendar
	err := h.db.Transaction(func(tx *gorm.DB) error {
		var latest models.CampusCalendar
		nextVersion := 1
		if err := tx.Where("academic_year = ?", document.AcademicYear).
			Order("version DESC").First(&latest).Error; err == nil {
			nextVersion = latest.Version + 1
		} else if err != gorm.ErrRecordNotFound {
			return err
		}

		hash := sha256.Sum256(raw)
		created = models.CampusCalendar{
			AcademicYear: document.AcademicYear,
			Version:      nextVersion,
			Status:       "draft",
			Data:         datatypes.JSON(raw),
			SourceName:   document.Source.Title,
			SourceHash:   hex.EncodeToString(hash[:]),
			CreatedBy:    userID,
		}
		return tx.Create(&created).Error
	})
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "创建校历草稿失败"})
		return
	}
	c.JSON(http.StatusCreated, gin.H{"item": created, "validation": result})
}

// Publish 原子归档同学年旧版本并发布指定草稿。
func (h *CampusCalendarHandler) Publish(c *gin.Context) {
	id, ok := parseCalendarID(c)
	if !ok {
		return
	}

	var published models.CampusCalendar
	err := h.db.Transaction(func(tx *gorm.DB) error {
		var target models.CampusCalendar
		if err := tx.First(&target, id).Error; err != nil {
			return err
		}
		if target.Status == "archived" {
			return errArchivedCalendar
		}
		if err := tx.Model(&models.CampusCalendar{}).
			Where("academic_year = ? AND status = ? AND id <> ?", target.AcademicYear, "published", target.ID).
			Update("status", "archived").Error; err != nil {
			return err
		}
		now := time.Now()
		if err := tx.Model(&target).Updates(map[string]interface{}{
			"status": "published", "published_at": now,
		}).Error; err != nil {
			return err
		}
		return tx.First(&published, target.ID).Error
	})
	if err != nil {
		if err == gorm.ErrRecordNotFound {
			c.JSON(http.StatusNotFound, gin.H{"error": "校历不存在"})
			return
		}
		if err == errArchivedCalendar {
			c.JSON(http.StatusConflict, gin.H{"error": "已归档校历不能直接发布"})
			return
		}
		c.JSON(http.StatusInternalServerError, gin.H{"error": "发布校历失败"})
		return
	}
	h.writeCalendar(c, published)
}

// Archive 将已发布或草稿校历归档，归档版本不会再被公共接口返回。
func (h *CampusCalendarHandler) Archive(c *gin.Context) {
	id, ok := parseCalendarID(c)
	if !ok {
		return
	}
	result := h.db.Model(&models.CampusCalendar{}).
		Where("id = ?", id).
		Update("status", "archived")
	if result.Error != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "归档校历失败"})
		return
	}
	if result.RowsAffected == 0 {
		c.JSON(http.StatusNotFound, gin.H{"error": "校历不存在"})
		return
	}
	c.Status(http.StatusNoContent)
}

func (h *CampusCalendarHandler) writeCalendar(c *gin.Context, calendar models.CampusCalendar) {
	var data interface{}
	if err := json.Unmarshal(calendar.Data, &data); err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "已发布校历数据损坏"})
		return
	}
	c.JSON(http.StatusOK, gin.H{
		"calendar":   data,
		"version":    calendar.Version,
		"updated_at": calendar.UpdatedAt,
	})
}

func readAndValidateCalendar(c *gin.Context) ([]byte, campusCalendarDocument, calendarValidationResult, bool) {
	limited := http.MaxBytesReader(c.Writer, c.Request.Body, 1024*1024)
	raw, err := io.ReadAll(limited)
	if err != nil {
		c.JSON(http.StatusRequestEntityTooLarge, gin.H{"error": "校历 JSON 不能超过 1 MB"})
		return nil, campusCalendarDocument{}, calendarValidationResult{}, false
	}
	result, document := validateCampusCalendar(raw)
	return raw, document, result, true
}

func validateCampusCalendar(raw []byte) (calendarValidationResult, campusCalendarDocument) {
	result := calendarValidationResult{Errors: []calendarValidationIssue{}, Warnings: []calendarValidationIssue{}}
	var document campusCalendarDocument
	if len(raw) == 0 || json.Unmarshal(raw, &document) != nil {
		result.Errors = append(result.Errors, calendarValidationIssue{Path: "$", Message: "必须提交合法 JSON"})
		return result, document
	}
	if document.SchemaVersion != 1 {
		result.Errors = append(result.Errors, calendarValidationIssue{Path: "schema_version", Message: "仅支持 schema_version=1"})
	}
	if !academicYearPattern.MatchString(document.AcademicYear) {
		result.Errors = append(result.Errors, calendarValidationIssue{Path: "academic_year", Message: "学年格式应为 YYYY-YYYY"})
	}
	if strings.TrimSpace(document.CalendarID) == "" {
		result.Errors = append(result.Errors, calendarValidationIssue{Path: "calendar_id", Message: "缺少校历标识"})
	}
	if strings.TrimSpace(document.School) == "" {
		result.Errors = append(result.Errors, calendarValidationIssue{Path: "school", Message: "缺少学校名称"})
	}
	if document.Timezone != "Asia/Shanghai" {
		result.Errors = append(result.Errors, calendarValidationIssue{Path: "timezone", Message: "时区必须为 Asia/Shanghai"})
	}
	if strings.TrimSpace(document.Source.Type) == "" || strings.TrimSpace(document.Source.Title) == "" || strings.TrimSpace(document.Source.FileName) == "" {
		result.Errors = append(result.Errors, calendarValidationIssue{Path: "source", Message: "来源类型、标题和文件名不能为空"})
	}
	if !document.Source.Verified {
		result.Errors = append(result.Errors, calendarValidationIssue{Path: "source.verified", Message: "校历必须完成来源核验后才能保存"})
	}
	if len(document.Semesters) == 0 {
		result.Errors = append(result.Errors, calendarValidationIssue{Path: "semesters", Message: "至少需要一个学期"})
	}

	for semesterIndex, semester := range document.Semesters {
		path := "semesters[" + strconv.Itoa(semesterIndex) + "]"
		if strings.TrimSpace(semester.ID) == "" || strings.TrimSpace(semester.Name) == "" {
			result.Errors = append(result.Errors, calendarValidationIssue{Path: path, Message: "学期标识和名称不能为空"})
		}
		start, startOK := validateCalendarDate(&result, path+".start_date", semester.StartDate)
		end, endOK := validateCalendarDate(&result, path+".end_date", semester.EndDate)
		if startOK && endOK && end.Before(start) {
			result.Errors = append(result.Errors, calendarValidationIssue{Path: path, Message: "学期结束日期早于开始日期"})
		}
		if len(semester.TeachingWeeks) == 0 {
			result.Warnings = append(result.Warnings, calendarValidationIssue{Path: path + ".teaching_weeks", Message: "该学期没有教学周"})
		}
		previousEnd := time.Time{}
		for weekIndex, week := range semester.TeachingWeeks {
			weekPath := path + ".teaching_weeks[" + strconv.Itoa(weekIndex) + "]"
			weekStart, weekStartOK := validateCalendarDate(&result, weekPath+".start_date", week.StartDate)
			weekEnd, weekEndOK := validateCalendarDate(&result, weekPath+".end_date", week.EndDate)
			if week.Week < 1 {
				result.Errors = append(result.Errors, calendarValidationIssue{Path: weekPath + ".week", Message: "教学周序号必须大于 0"})
			}
			if weekStartOK && weekEndOK {
				if weekEnd.Before(weekStart) {
					result.Errors = append(result.Errors, calendarValidationIssue{Path: weekPath, Message: "教学周结束日期早于开始日期"})
				}
				if !previousEnd.IsZero() && !weekStart.After(previousEnd) {
					result.Errors = append(result.Errors, calendarValidationIssue{Path: weekPath, Message: "教学周与上一周日期重叠"})
				}
				if (startOK && weekStart.Before(start)) || (endOK && weekEnd.After(end)) {
					result.Errors = append(result.Errors, calendarValidationIssue{Path: weekPath, Message: "教学周超出所属学期范围"})
				}
				previousEnd = weekEnd
			}
		}
	}

	for index, event := range document.Events {
		path := "events[" + strconv.Itoa(index) + "]"
		if strings.TrimSpace(event.ID) == "" || strings.TrimSpace(event.Title) == "" || strings.TrimSpace(event.Type) == "" {
			result.Errors = append(result.Errors, calendarValidationIssue{Path: path, Message: "事件标识、标题和类型不能为空"})
		}
		validateDateRange(&result, path, event.StartDate, event.EndDate)
	}
	seenOverrides := make(map[string]struct{})
	for index, override := range document.Overrides {
		path := "day_overrides[" + strconv.Itoa(index) + "].date"
		if strings.TrimSpace(override.DayMode) == "" {
			result.Errors = append(result.Errors, calendarValidationIssue{Path: "day_overrides[" + strconv.Itoa(index) + "].day_mode", Message: "覆盖规则缺少 day_mode"})
		}
		_, valid := validateCalendarDate(&result, path, override.Date)
		if valid {
			if _, exists := seenOverrides[override.Date]; exists {
				result.Errors = append(result.Errors, calendarValidationIssue{Path: path, Message: "同一天只能有一条覆盖规则"})
			}
			seenOverrides[override.Date] = struct{}{}
		}
	}

	sort.Slice(result.Errors, func(i, j int) bool { return result.Errors[i].Path < result.Errors[j].Path })
	result.Valid = len(result.Errors) == 0
	return result, document
}

func validateDateRange(result *calendarValidationResult, path, startValue, endValue string) {
	start, startOK := validateCalendarDate(result, path+".start_date", startValue)
	end, endOK := validateCalendarDate(result, path+".end_date", endValue)
	if startOK && endOK && end.Before(start) {
		result.Errors = append(result.Errors, calendarValidationIssue{Path: path, Message: "结束日期早于开始日期"})
	}
}

func validateCalendarDate(result *calendarValidationResult, path, value string) (time.Time, bool) {
	date, err := time.Parse(calendarDateLayout, value)
	if err != nil || date.Format(calendarDateLayout) != value {
		result.Errors = append(result.Errors, calendarValidationIssue{Path: path, Message: "日期必须为 YYYY-MM-DD"})
		return time.Time{}, false
	}
	return date, true
}

var errArchivedCalendar = errors.New("archived campus calendar")

func parseCalendarID(c *gin.Context) (uint, bool) {
	id, err := strconv.ParseUint(c.Param("id"), 10, 64)
	if err != nil || id == 0 {
		c.JSON(http.StatusBadRequest, gin.H{"error": "无效的校历 ID"})
		return 0, false
	}
	return uint(id), true
}
