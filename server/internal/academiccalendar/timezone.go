package academiccalendar

import (
	"errors"
	"fmt"
	"time"
)

// ShanghaiLocation 是所有校历与课表相对日期计算的唯一时区来源。
var ShanghaiLocation *time.Location

// ErrTimezoneUnavailable 表示上海时区尚未初始化。任何"上海自然日"计算都必须
// 显式失败，而不是退回机器默认时区（容器里通常是 UTC）静默算错 8 小时。
var ErrTimezoneUnavailable = errors.New("Asia/Shanghai timezone is not initialized")

var loadLocation = time.LoadLocation

// InitializeTimezone 从随 Go 程序携带的 IANA tzdata 初始化上海时区。
//
// 成功时 ShanghaiLocation 与 time.Local 同时指向上海，避免两者随容器是否安装
// tzdata 而分叉；失败时不改写任何全局状态，由调用方 fail-fast。
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

// DayStart 返回 at 所在上海自然日的零点。
//
// 每日唯一键（每日经验、日榜计数）必须走这里，不能再用 time.Local 直接截断：
// 后者在时区未初始化时会静默按 UTC 计算，导致每日额度在北京时间 08:00 翻页。
func DayStart(at time.Time) (time.Time, error) {
	if ShanghaiLocation == nil {
		return time.Time{}, ErrTimezoneUnavailable
	}
	local := at.In(ShanghaiLocation)
	return time.Date(local.Year(), local.Month(), local.Day(), 0, 0, 0, 0, ShanghaiLocation), nil
}

// RelativeDate 将“今天前后 N 天”严格按上海自然日计算。
func RelativeDate(now time.Time, days int) (time.Time, error) {
	if ShanghaiLocation == nil {
		return time.Time{}, ErrTimezoneUnavailable
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
