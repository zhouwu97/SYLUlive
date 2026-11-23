package models

import (
	"fmt"
	"strings"
	"time"

	"gorm.io/gorm"
	"gorm.io/gorm/clause"
)

// CanteenLocationMigrationVersion 一次性迁移版本号：
// 解析现有店铺名中的位置信息（一食堂/二食堂 + 一楼/二楼）写入结构化字段，
// 并把店铺名改写为纯店铺名（"一食堂二楼 老麻抄手" → 位置=一食堂+二楼，店名="老麻抄手"）。
const CanteenLocationMigrationVersion = "20260829_02_canteen_location"

const canteenNameIndexMigrationVersion = "20261123_01_canteen_name_index"

// canteenLocationTokens 店名中的位置关键词 → 标准标签。
// 匹配时按长度降序扫描，避免"第一食堂"被"一食堂"截断误匹配。
var canteenLocationTokens = []struct {
	token string
	area  string
	floor string
}{
	{"第一食堂", CanteenLocationArea1, ""},
	{"第二食堂", CanteenLocationArea2, ""},
	{"1号食堂", CanteenLocationArea1, ""},
	{"2号食堂", CanteenLocationArea2, ""},
	{"一食堂", CanteenLocationArea1, ""},
	{"二食堂", CanteenLocationArea2, ""},
	{"1食堂", CanteenLocationArea1, ""},
	{"2食堂", CanteenLocationArea2, ""},
	{"一楼", "", CanteenLocationFloor1},
	{"二楼", "", CanteenLocationFloor2},
	{"1楼", "", CanteenLocationFloor1},
	{"2楼", "", CanteenLocationFloor2},
	{"一层", "", CanteenLocationFloor1},
	{"二层", "", CanteenLocationFloor2},
	{"1F", "", CanteenLocationFloor1},
	{"2F", "", CanteenLocationFloor2},
	{"1f", "", CanteenLocationFloor1},
	{"2f", "", CanteenLocationFloor2},
}

// canteenNameTrimChars 摘除位置词后需要从店名两端清理的连接符。
const canteenNameTrimChars = " \t-—－~～·•/|｜:：_（）()【】[]"

// parseCanteenLocationFromName 从店铺名中解析位置标签并返回纯店铺名。
// 解析结果可能为部分命中（只有区域或只有楼层）；cleaned 为空时调用方应保留原名。
func parseCanteenLocationFromName(name string) (area, floor, cleaned string) {
	area = ""
	floor = ""
	cleaned = name

	// 按长度降序匹配并移除，防止长词被短词截断。
	tokens := make([]string, 0, len(canteenLocationTokens))
	for _, t := range canteenLocationTokens {
		tokens = append(tokens, t.token)
	}
	for i := 0; i < len(tokens); i++ {
		for j := i + 1; j < len(tokens); j++ {
			if len([]rune(tokens[j])) > len([]rune(tokens[i])) {
				tokens[i], tokens[j] = tokens[j], tokens[i]
			}
		}
	}

	for _, token := range tokens {
		if !strings.Contains(cleaned, token) {
			continue
		}
		for _, t := range canteenLocationTokens {
			if t.token != token {
				continue
			}
			if t.area != "" && area == "" {
				area = t.area
			}
			if t.floor != "" && floor == "" {
				floor = t.floor
			}
		}
		cleaned = strings.ReplaceAll(cleaned, token, "")
	}

	// 清理残留的空括号与两端连接符。
	for _, pair := range []string{"（）", "()", "【】", "[]"} {
		cleaned = strings.ReplaceAll(cleaned, pair, "")
	}
	cleaned = strings.Trim(cleaned, canteenNameTrimChars)
	cleaned = strings.Join(strings.Fields(cleaned), " ")
	return area, floor, cleaned
}

// normalizeCanteenLocationName 与 handlers.normalizeCanteenName 保持一致：
// 小写 + 空白折叠。迁移在 models 包内独立实现以避免包循环依赖。
func normalizeCanteenLocationName(name string) string {
	return strings.ToLower(strings.Join(strings.Fields(strings.TrimSpace(name)), " "))
}

// MigrateCanteenLocations 将旧位置回填和索引切换放在同一事务，失败时恢复原有约束。
func MigrateCanteenLocations(db *gorm.DB) error {
	if err := db.AutoMigrate(&AppSchemaMigration{}); err != nil {
		return err
	}
	return db.Transaction(func(tx *gorm.DB) error {
		// 主键冲突使并发启动者等待先行事务，只有成功提交的版本会跳过迁移。
		claim := tx.Clauses(clause.OnConflict{DoNothing: true}).Create(&AppSchemaMigration{
			Version: canteenNameIndexMigrationVersion, AppliedAt: time.Now().UTC(),
		})
		if claim.Error != nil || claim.RowsAffected == 0 {
			return claim.Error
		}
		if tx.Dialector.Name() == "postgres" {
			if err := tx.Exec("LOCK TABLE canteens IN ACCESS EXCLUSIVE MODE").Error; err != nil {
				return err
			}
		}
		if err := tx.Exec("DROP INDEX IF EXISTS idx_canteens_normalized_name").Error; err != nil {
			return err
		}
		location := tx.Clauses(clause.OnConflict{DoNothing: true}).Create(&AppSchemaMigration{
			Version: CanteenLocationMigrationVersion, AppliedAt: time.Now().UTC(),
		})
		if location.Error != nil {
			return location.Error
		}
		if location.RowsAffected > 0 {
			if err := backfillCanteenLocations(tx); err != nil {
				return err
			}
		}
		return createCanteenNameIndex(tx)
	})
}

func backfillCanteenLocations(tx *gorm.DB) error {
	var canteens []Canteen
	if err := tx.Order("id ASC").Find(&canteens).Error; err != nil {
		return err
	}
	type locationKey struct {
		normalized string
		area       string
		floor      string
	}
	used := make(map[locationKey]uint, len(canteens))

	for _, canteen := range canteens {
		area, floor, cleaned := parseCanteenLocationFromName(canteen.Name)
		renamed := false

		if cleaned != "" && cleaned != canteen.Name {
			candidate := locationKey{
				normalized: normalizeCanteenLocationName(cleaned),
				area:       firstNonEmpty(area, canteen.LocationArea),
				floor:      firstNonEmpty(floor, canteen.LocationFloor),
			}
			if _, taken := used[candidate]; !taken {
				if err := tx.Model(&Canteen{}).Where("id = ?", canteen.ID).
					Updates(map[string]interface{}{
						"name":            cleaned,
						"normalized_name": candidate.normalized,
						"location_area":   candidate.area,
						"location_floor":  candidate.floor,
					}).Error; err != nil {
					return err
				}
				used[candidate] = canteen.ID
				renamed = true
			}
		}
		if renamed {
			continue
		}

		// 保留原店名：仅补写解析出的位置字段（若有）。
		fallback := locationKey{
			normalized: normalizeCanteenLocationName(canteen.Name),
			area:       firstNonEmpty(area, canteen.LocationArea),
			floor:      firstNonEmpty(floor, canteen.LocationFloor),
		}
		updates := map[string]interface{}{}
		if area != "" && canteen.LocationArea == "" {
			updates["location_area"] = area
		}
		if floor != "" && canteen.LocationFloor == "" {
			updates["location_floor"] = floor
		}
		if len(updates) > 0 {
			if err := tx.Model(&Canteen{}).Where("id = ?", canteen.ID).
				Updates(updates).Error; err != nil {
				return err
			}
		}
		if _, taken := used[fallback]; !taken {
			used[fallback] = canteen.ID
		}
	}
	return nil
}

func createCanteenNameIndex(db *gorm.DB) error {
	var canteens []Canteen
	if err := db.Select("id", "name", "normalized_name", "location_area", "location_floor", "verified", "rejected_at").Find(&canteens).Error; err != nil {
		return err
	}
	type locationKey struct {
		normalized string
		area       string
		floor      string
	}
	seen := make(map[locationKey]uint, len(canteens))
	for _, canteen := range canteens {
		normalized := normalizeCanteenLocationName(canteen.Name)
		// 被驳回的提交保留记录但不占真实店名，规范名固定为占位值，否则同名重新提交会让启动失败。
		if canteen.IsRejected() {
			normalized = CanteenRejectedNormalizedName(canteen.ID)
		}
		key := locationKey{
			normalized: normalized,
			area:       canteen.LocationArea,
			floor:      canteen.LocationFloor,
		}
		if previousID, exists := seen[key]; exists {
			return fmt.Errorf("食堂名称规范化后重复: id=%d, id=%d", previousID, canteen.ID)
		}
		seen[key] = canteen.ID
		if canteen.NormalizedName != normalized {
			if err := db.Model(&Canteen{}).Where("id = ?", canteen.ID).Update("normalized_name", normalized).Error; err != nil {
				return err
			}
		}
	}
	return db.Exec("CREATE UNIQUE INDEX idx_canteens_normalized_name ON canteens (normalized_name, location_area, location_floor)").Error
}

func firstNonEmpty(values ...string) string {
	for _, v := range values {
		if v != "" {
			return v
		}
	}
	return ""
}
