package academiccalendar

import (
	"errors"
	"testing"
	"time"
)

func TestShanghaiTimezoneLoads(t *testing.T) {
	original := loadLocation
	t.Cleanup(func() { loadLocation = original })
	loadLocation = time.LoadLocation

	if err := InitializeTimezone(); err != nil {
		t.Fatalf("上海时区加载失败: %v", err)
	}
	if ShanghaiLocation == nil || ShanghaiLocation.String() != "Asia/Shanghai" {
		t.Fatalf("上海时区未正确初始化: %v", ShanghaiLocation)
	}
}

func TestTimezoneInitializationFailsWhenTimezoneUnavailable(t *testing.T) {
	original := loadLocation
	t.Cleanup(func() {
		loadLocation = original
		_ = InitializeTimezone()
	})
	loadLocation = func(string) (*time.Location, error) {
		return nil, errors.New("tzdata unavailable")
	}

	if err := InitializeTimezone(); err == nil {
		t.Fatal("时区不可用时应返回错误")
	}
	if ShanghaiLocation != nil {
		t.Fatal("时区初始化失败后不得保留可用状态")
	}
}

func TestRelativeDateUsesShanghaiTimezone(t *testing.T) {
	if err := InitializeTimezone(); err != nil {
		t.Fatal(err)
	}
	now := time.Date(2026, 7, 19, 16, 30, 0, 0, time.UTC) // 上海已是次日。
	got, err := RelativeDate(now, 0)
	if err != nil {
		t.Fatal(err)
	}
	if got.Format("2006-01-02 15:04 MST") != "2026-07-20 00:00 CST" {
		t.Fatalf("相对日期未使用上海自然日: %s", got)
	}
}

func TestTeachingWeekBoundaryUsesShanghaiDate(t *testing.T) {
	if err := InitializeTimezone(); err != nil {
		t.Fatal(err)
	}
	start, end, err := TeachingWeekBoundary(time.Date(2026, 7, 19, 16, 30, 0, 0, time.UTC))
	if err != nil {
		t.Fatal(err)
	}
	if start.Format("2006-01-02") != "2026-07-20" || end.Format("2006-01-02") != "2026-07-26" {
		t.Fatalf("教学周边界错误: %s - %s", start, end)
	}
}
