package models

import (
	"log"
	"strings"
	"time"

	"gorm.io/gorm"
)

// CanteenLocationMigrationVersion 一次性迁移版本号：
// 解析现有店铺名中的位置信息（一食堂/二食堂 + 一楼/二楼）写入结构化字段，
// 并把店铺名改写为纯店铺名（"一食堂二楼 老麻抄手" → 位置=一食堂+二楼，店名="老麻抄手"）。
const CanteenLocationMigrationVersion = "20260829_02_canteen_location"

// canteenLocationTokens 店名中的位置关键词 → 标准标签。
// 匹配时按长度降序扫描，避免"第一食堂"被"一食堂"截断误匹配。
var canteenLocationTokens = []struct {
	token  string
	area   string
	floor  string
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

// MigrateCanteenLocations 一次性迁移历史店铺名（幂等，版本化）：
//  1. 解析店名中的位置关键词，写入 location_area / location_floor；
//  2. 店名改写为纯店铺名，同步更新 normalized_name；
//  3. 改名后与既有店铺撞名时保留原名（位置字段仍然写入）；
//  4. 移除旧的 normalized_name 单列唯一索引，为复合唯一索引让路
//     （复合索引由 ensureCanteenNormalizedNameIndex 重建）。
//
// 兼容旧的单列唯一索引：若不移除，改名可能与其他店铺撞名导致迁移失败。
func MigrateCanteenLocations(db *gorm.DB) error {
	if err := db.AutoMigrate(&AppSchemaMigration{}); err != nil {
		return err
	}
	var existing AppSchemaMigration
	if err := db.Where("version = ?", CanteenLocationMigrationVersion).First(&existing).Error; err == nil {
		return nil
	}

	// 先移除旧单列唯一索引，避免改名过程中撞名失败（幂等）。
	if err := db.Exec("DROP INDEX IF EXISTS idx_canteens_normalized_name").Error; err != nil {
		return err
	}

	var canteens []Canteen
	if err := db.Order("id ASC").Find(&canteens).Error; err != nil {
		return err
	}
	if len(canteens) == 0 {
		return db.Create(&AppSchemaMigration{
			Version:   CanteenLocationMigrationVersion,
			AppliedAt: time.Now().UTC(),
		}).Error
	}

	type locationKey struct {
		normalized string
		area       string
		floor      string
	}
	used := make(map[locationKey]uint, len(canteens))

	return db.Transaction(func(tx *gorm.DB) error {
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

		if err := tx.Create(&AppSchemaMigration{
			Version:   CanteenLocationMigrationVersion,
			AppliedAt: time.Now().UTC(),
		}).Error; err != nil {
			return err
		}
		log.Printf("食堂位置标签迁移完成: 共 %d 家店铺", len(canteens))
		return nil
	})
}

func firstNonEmpty(values ...string) string {
	for _, v := range values {
		if v != "" {
			return v
		}
	}
	return ""
}
