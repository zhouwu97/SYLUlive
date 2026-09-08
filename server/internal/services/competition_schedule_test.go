package services

import (
	"testing"
	"time"

	"shenliyuan/internal/dto"
	"shenliyuan/internal/models"
)

func TestCompetitionScheduleDateOnlyUsesShanghaiDayAndSort(t *testing.T) {
	importer := NewCompetitionCatalogImporter(nil)
	record := dto.CompetitionCatalogRecord{
		CompetitionID: "NAT-TEST", Title: "日程测试", TimeStatus: "confirmed",
		RegistrationStart: "2026-09-01", RegistrationEnd: "2026-09-11",
	}
	event, err := importer.eventFromCatalogRecord(nil, models.CompetitionCatalogPackage{}, record, time.Now())
	if err != nil {
		t.Fatal(err)
	}
	if event.RegistrationStart.Format(time.RFC3339) != "2026-09-01T00:00:00+08:00" ||
		event.RegistrationEnd.Format(time.RFC3339) != "2026-09-11T23:59:59+08:00" {
		t.Fatalf("日期边界错误: %v / %v", event.RegistrationStart, event.RegistrationEnd)
	}
	if event.SortDate == nil || !event.SortDate.Equal(*event.RegistrationEnd) {
		t.Fatal("日程未进入目录排序")
	}
	updates := catalogEventUpdates(event)
	if updates["sort_date"] == nil {
		t.Fatal("更新已有赛事时丢失排序日期")
	}
}

func TestCompetitionScheduleExactTimestampKeepsDeadline(t *testing.T) {
	importer := NewCompetitionCatalogImporter(nil)
	record := dto.CompetitionCatalogRecord{
		CompetitionID: "NAT-TEST", Title: "日程测试", TimeStatus: "confirmed",
		RegistrationEnd: "2026-09-19T17:00:00+08:00",
	}
	event, err := importer.eventFromCatalogRecord(nil, models.CompetitionCatalogPackage{}, record, time.Now())
	if err != nil {
		t.Fatal(err)
	}
	expected, _ := time.Parse(time.RFC3339, record.RegistrationEnd)
	if !event.RegistrationEnd.Equal(expected) {
		t.Fatalf("精确截止时刻被覆盖: %v", event.RegistrationEnd)
	}
}

func TestCompetitionScheduleMissingDatesDoNotUseImportTime(t *testing.T) {
	importer := NewCompetitionCatalogImporter(nil)
	event, err := importer.eventFromCatalogRecord(nil, models.CompetitionCatalogPackage{},
		dto.CompetitionCatalogRecord{CompetitionID: "NAT-TEST", Title: "未核实", TimeStatus: "pending"}, time.Now())
	if err != nil {
		t.Fatal(err)
	}
	if event.SortDate != nil || event.RegistrationEnd != nil {
		t.Fatal("未核实日程不应推定日期")
	}
}
