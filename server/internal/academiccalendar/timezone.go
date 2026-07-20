package academiccalendar

import (
	"fmt"
	"time"
)

// ShanghaiLocation 是所有校历与课表相对日期计算的唯一时区来源。
var ShanghaiLocation *time.Location

var loadLocation = time.LoadLocation

// InitializeTimezone 从随 Go 程序携带的 IANA tzdata 初始化上海时区。
func InitializeTimezone() error {
	location, err := loadLocation("Asia/Shanghai")
	if err != nil {
		ShanghaiLocation = nil
		return fmt.Errorf("load Asia/Shanghai timezone: %w", err)
	}
	ShanghaiLocation = location
	time.Local = location
	return nil
}

// RelativeDate 将“今天前后 N 天”严格按上海自然日计算。
func RelativeDate(now time.Time, days int) (time.Time, error) {
	if ShanghaiLocation == nil {
		return time.Time{}, fmt.Errorf("Asia/Shanghai timezone is not initialized")
	}
	local := now.In(ShanghaiLocation)
	return time.Date(local.Year(), local.Month(), local.Day()+days, 0, 0, 0, 0, ShanghaiLocation), nil
}

// TeachingWeekBoundary 返回给定日期所在教学周的上海自然日边界（周一至周日）。
func TeachingWeekBoundary(at time.Time) (time.Time, time.Time, error) {
	day, err := RelativeDate(at, 0)
	if err != nil {
		return time.Time{}, time.Time{}, err
	}
	offset := (int(day.Weekday()) + 6) % 7
	start := day.AddDate(0, 0, -offset)
	return start, start.AddDate(0, 0, 6), nil
}
