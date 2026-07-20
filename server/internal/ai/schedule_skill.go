package ai

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"sort"
	"strings"
	"time"

	"gorm.io/gorm"

	"shenliyuan/internal/academiccalendar"
	"shenliyuan/internal/models"
)

type ScheduleCacheReader interface {
	Read(context.Context, uint, string, int) ([]CachedCourse, error)
}

type ScheduleWindowsArguments struct {
	Scope              string `json:"scope"`
	ExplicitDate       string `json:"explicit_date,omitempty"`
	MinimumFreeMinutes int    `json:"minimum_free_minutes"`
	PreferredDaypart   string `json:"preferred_daypart,omitempty"`
}

type ScheduleWindow struct {
	StartTime    string `json:"start_time"`
	EndTime      string `json:"end_time"`
	Minutes      int    `json:"minutes"`
	StartSection int    `json:"start_section"`
	EndSection   int    `json:"end_section"`
}

type ScheduleDayResult struct {
	Date          string           `json:"date"`
	TeachingWeek  int              `json:"teaching_week"`
	ScheduleAsDay int              `json:"schedule_as_weekday"`
	NoTeaching    bool             `json:"no_teaching"`
	Courses       []CachedCourse   `json:"courses"`
	FreeWindows   []ScheduleWindow `json:"free_windows"`
}

type ScheduleWindowsResult struct {
	Status          string              `json:"status"`
	Reason          string              `json:"reason,omitempty"`
	Source          string              `json:"source"`
	Freshness       string              `json:"freshness"`
	SuggestedAction string              `json:"suggested_action,omitempty"`
	Days            []ScheduleDayResult `json:"days,omitempty"`
}

type scheduleCalendarDocument struct {
	SchemaVersion int    `json:"schema_version"`
	AcademicYear  string `json:"academic_year"`
	Semesters     []struct {
		EduSemesterCode *int   `json:"edu_semester_code"`
		StartDate       string `json:"start_date"`
		EndDate         string `json:"end_date"`
		TeachingWeeks   []struct {
			Week      int    `json:"week"`
			StartDate string `json:"start_date"`
			EndDate   string `json:"end_date"`
		} `json:"teaching_weeks"`
	} `json:"semesters"`
	DayOverrides []struct {
		Date              string `json:"date"`
		DayMode           string `json:"day_mode"`
		ScheduleAsWeekday *int   `json:"schedule_as_weekday"`
	} `json:"day_overrides"`
}

type classPeriod struct {
	Section   int    `json:"section"`
	StartTime string `json:"start_time"`
	EndTime   string `json:"end_time"`
}

type ScheduleSkill struct {
	db     *gorm.DB
	reader ScheduleCacheReader
	now    func() time.Time
}

func NewScheduleSkill(db *gorm.DB, reader ScheduleCacheReader) *ScheduleSkill {
	return &ScheduleSkill{db: db, reader: reader, now: time.Now}
}

func (s *ScheduleSkill) Execute(ctx context.Context, userID uint, arguments ScheduleWindowsArguments) (ScheduleWindowsResult, error) {
	if academiccalendar.ShanghaiLocation == nil {
		return unavailableSchedule("timezone_unavailable", "请联系管理员检查服务器时区"), nil
	}
	if err := validateScheduleArguments(arguments); err != nil {
		return ScheduleWindowsResult{}, err
	}
	dates, err := resolveScheduleDates(s.now().In(academiccalendar.ShanghaiLocation), arguments)
	if err != nil {
		return ScheduleWindowsResult{}, err
	}
	var calendars []models.CampusCalendar
	if err := s.db.WithContext(ctx).Where("status = ?", "published").Order("academic_year DESC").Find(&calendars).Error; err != nil {
		return ScheduleWindowsResult{}, err
	}
	cache := make(map[string][]CachedCourse)
	result := ScheduleWindowsResult{Status: "ok", Source: "edu_local_cache", Freshness: "unknown", Days: []ScheduleDayResult{}}
	for _, date := range dates {
		calendar, document, semesterCode, teachingWeek, scheduleWeekday, noTeaching, mappingReason := resolveScheduleDay(calendars, date)
		if mappingReason != "" {
			return unavailableSchedule(mappingReason, "请等待管理员发布并核验新版校历"), nil
		}
		periods, err := s.loadPeriodProfile(ctx, calendar.AcademicYear, date)
		if errors.Is(err, gorm.ErrRecordNotFound) {
			return unavailableSchedule("class_period_profile_missing", "请等待管理员发布节次时间配置"), nil
		}
		if err != nil {
			return ScheduleWindowsResult{}, err
		}
		key := fmt.Sprintf("%s:%d", document.AcademicYear, semesterCode)
		courses, exists := cache[key]
		if !exists {
			courses, err = s.reader.Read(ctx, userID, document.AcademicYear, semesterCode)
			if err != nil {
				return unavailableSchedule("schedule_cache_unavailable", "请稍后重试"), nil
			}
			if len(courses) == 0 {
				return unavailableSchedule("schedule_cache_empty", "请先打开原课表页面完成同步"), nil
			}
			cache[key] = courses
		}
		active := activeCourses(courses, teachingWeek, scheduleWeekday, noTeaching)
		windows := calculateFreeWindows(periods, active, arguments.MinimumFreeMinutes, arguments.PreferredDaypart)
		result.Days = append(result.Days, ScheduleDayResult{
			Date: date.Format("2006-01-02"), TeachingWeek: teachingWeek,
			ScheduleAsDay: scheduleWeekday, NoTeaching: noTeaching,
			Courses: active, FreeWindows: windows,
		})
	}
	return result, nil
}

func validateScheduleArguments(arguments ScheduleWindowsArguments) error {
	switch arguments.Scope {
	case "today", "tomorrow", "this_week", "next_week":
		if strings.TrimSpace(arguments.ExplicitDate) != "" {
			return errors.New("explicit_date is only allowed with explicit_date scope")
		}
	case "explicit_date":
		if _, err := time.Parse("2006-01-02", arguments.ExplicitDate); err != nil {
			return errors.New("explicit_date must be an absolute YYYY-MM-DD date")
		}
	default:
		return errors.New("invalid schedule scope")
	}
	if arguments.MinimumFreeMinutes < 15 || arguments.MinimumFreeMinutes > 720 {
		return errors.New("minimum_free_minutes must be between 15 and 720")
	}
	if arguments.PreferredDaypart != "" && arguments.PreferredDaypart != "morning" && arguments.PreferredDaypart != "afternoon" && arguments.PreferredDaypart != "evening" {
		return errors.New("invalid preferred_daypart")
	}
	return nil
}

func resolveScheduleDates(now time.Time, arguments ScheduleWindowsArguments) ([]time.Time, error) {
	date := time.Date(now.Year(), now.Month(), now.Day(), 0, 0, 0, 0, academiccalendar.ShanghaiLocation)
	switch arguments.Scope {
	case "today":
		return []time.Time{date}, nil
	case "tomorrow":
		return []time.Time{date.AddDate(0, 0, 1)}, nil
	case "explicit_date":
		parsed, err := time.ParseInLocation("2006-01-02", arguments.ExplicitDate, academiccalendar.ShanghaiLocation)
		return []time.Time{parsed}, err
	case "this_week", "next_week":
		weekday := int(date.Weekday())
		if weekday == 0 {
			weekday = 7
		}
		monday := date.AddDate(0, 0, 1-weekday)
		if arguments.Scope == "next_week" {
			monday = monday.AddDate(0, 0, 7)
		}
		result := make([]time.Time, 7)
		for index := range result {
			result[index] = monday.AddDate(0, 0, index)
		}
		return result, nil
	default:
		return nil, errors.New("invalid schedule scope")
	}
}

func resolveScheduleDay(calendars []models.CampusCalendar, date time.Time) (models.CampusCalendar, scheduleCalendarDocument, int, int, int, bool, string) {
	dateText := date.Format("2006-01-02")
	for _, calendar := range calendars {
		var document scheduleCalendarDocument
		if json.Unmarshal(calendar.Data, &document) != nil {
			continue
		}
		for _, semester := range document.Semesters {
			if dateText < semester.StartDate || dateText > semester.EndDate {
				continue
			}
			if document.SchemaVersion != 2 || semester.EduSemesterCode == nil || (*semester.EduSemesterCode != 3 && *semester.EduSemesterCode != 12) {
				return calendar, document, 0, 0, 0, false, "edu_semester_mapping_missing"
			}
			week := 0
			for _, teachingWeek := range semester.TeachingWeeks {
				if dateText >= teachingWeek.StartDate && dateText <= teachingWeek.EndDate {
					week = teachingWeek.Week
					break
				}
			}
			if week == 0 {
				return calendar, document, *semester.EduSemesterCode, 0, int(date.Weekday()), true, ""
			}
			weekday := int(date.Weekday())
			if weekday == 0 {
				weekday = 7
			}
			noTeaching := false
			for _, override := range document.DayOverrides {
				if override.Date != dateText {
					continue
				}
				if override.DayMode == "no_teaching" {
					noTeaching = true
				}
				if override.DayMode == "makeup_teaching" && override.ScheduleAsWeekday != nil {
					weekday = *override.ScheduleAsWeekday
				}
			}
			return calendar, document, *semester.EduSemesterCode, week, weekday, noTeaching, ""
		}
	}
	return models.CampusCalendar{}, scheduleCalendarDocument{}, 0, 0, 0, false, "date_outside_published_semesters"
}

func (s *ScheduleSkill) loadPeriodProfile(ctx context.Context, academicYear string, date time.Time) ([]classPeriod, error) {
	var profile models.ClassPeriodProfile
	if err := s.db.WithContext(ctx).Where(
		"academic_year = ? AND status = ? AND effective_from <= ? AND effective_to >= ?",
		academicYear, "published", date, date,
	).Order("published_at DESC").First(&profile).Error; err != nil {
		return nil, err
	}
	var periods []classPeriod
	if err := json.Unmarshal(profile.Periods, &periods); err != nil || len(periods) == 0 {
		return nil, errors.New("invalid class period profile")
	}
	sort.Slice(periods, func(i, j int) bool { return periods[i].Section < periods[j].Section })
	return periods, nil
}

func activeCourses(courses []CachedCourse, week, weekday int, noTeaching bool) []CachedCourse {
	if noTeaching || week == 0 {
		return []CachedCourse{}
	}
	result := make([]CachedCourse, 0)
	for _, course := range courses {
		if course.Weekday != weekday || !containsWeek(course.Weeks, week) {
			continue
		}
		result = append(result, course)
	}
	sort.Slice(result, func(i, j int) bool { return result[i].StartSection < result[j].StartSection })
	return result
}

func containsWeek(weeks []int, target int) bool {
	for _, week := range weeks {
		if week == target {
			return true
		}
	}
	return false
}

func calculateFreeWindows(periods []classPeriod, courses []CachedCourse, minimumMinutes int, daypart string) []ScheduleWindow {
	periodBySection := make(map[int]classPeriod, len(periods))
	for _, period := range periods {
		periodBySection[period.Section] = period
	}
	type interval struct{ start, end int }
	busy := make([]interval, 0, len(courses))
	for _, course := range courses {
		start, startOK := periodBySection[course.StartSection]
		end, endOK := periodBySection[course.EndSection]
		if !startOK || !endOK {
			continue
		}
		busy = append(busy, interval{clockMinutes(start.StartTime), clockMinutes(end.EndTime)})
	}
	sort.Slice(busy, func(i, j int) bool { return busy[i].start < busy[j].start })
	merged := make([]interval, 0, len(busy))
	for _, current := range busy {
		if len(merged) == 0 || current.start > merged[len(merged)-1].end {
			merged = append(merged, current)
		} else if current.end > merged[len(merged)-1].end {
			merged[len(merged)-1].end = current.end
		}
	}
	dayStart, dayEnd := clockMinutes(periods[0].StartTime), clockMinutes(periods[len(periods)-1].EndTime)
	if daypart != "" {
		partStart, partEnd := daypartBounds(daypart)
		if partStart > dayStart {
			dayStart = partStart
		}
		if partEnd < dayEnd {
			dayEnd = partEnd
		}
	}
	free := make([]interval, 0, len(merged)+1)
	cursor := dayStart
	for _, current := range merged {
		if current.end <= dayStart || current.start >= dayEnd {
			continue
		}
		if current.start > cursor {
			free = append(free, interval{cursor, minInt(current.start, dayEnd)})
		}
		if current.end > cursor {
			cursor = current.end
		}
	}
	if cursor < dayEnd {
		free = append(free, interval{cursor, dayEnd})
	}
	result := make([]ScheduleWindow, 0, len(free))
	for _, current := range free {
		if current.end-current.start < minimumMinutes {
			continue
		}
		startSection, endSection := nearestSections(periods, current.start, current.end)
		result = append(result, ScheduleWindow{
			StartTime: formatClock(current.start), EndTime: formatClock(current.end),
			Minutes: current.end - current.start, StartSection: startSection, EndSection: endSection,
		})
	}
	return result
}

func clockMinutes(value string) int {
	parsed, err := time.Parse("15:04", value)
	if err != nil {
		return 0
	}
	return parsed.Hour()*60 + parsed.Minute()
}

func formatClock(value int) string { return fmt.Sprintf("%02d:%02d", value/60, value%60) }

func daypartBounds(daypart string) (int, int) {
	switch daypart {
	case "morning":
		return 0, 12 * 60
	case "afternoon":
		return 12 * 60, 18 * 60
	case "evening":
		return 18 * 60, 24 * 60
	default:
		return 0, 24 * 60
	}
}

func nearestSections(periods []classPeriod, start, end int) (int, int) {
	startSection, endSection := 0, 0
	for _, period := range periods {
		if clockMinutes(period.StartTime) >= start && startSection == 0 {
			startSection = period.Section
		}
		if clockMinutes(period.EndTime) <= end {
			endSection = period.Section
		}
	}
	return startSection, endSection
}

func minInt(left, right int) int {
	if left < right {
		return left
	}
	return right
}

func unavailableSchedule(reason, action string) ScheduleWindowsResult {
	return ScheduleWindowsResult{
		Status: "data_unavailable", Reason: reason, Source: "edu_local_cache",
		Freshness: "unknown", SuggestedAction: action,
	}
}
