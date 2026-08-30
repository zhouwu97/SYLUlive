package models

import (
	"path/filepath"
	"testing"

	"github.com/glebarez/sqlite"
	"gorm.io/gorm"
)

func newCanteenLocationTestDB(t *testing.T) *gorm.DB {
	t.Helper()
	db, err := gorm.Open(sqlite.Open(filepath.Join(t.TempDir(), "canteen_location.db")), &gorm.Config{})
	if err != nil {
		t.Fatal(err)
	}
	sqlDB, err := db.DB()
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = sqlDB.Close() })
	if err := db.AutoMigrate(&Canteen{}, &AppSchemaMigration{}); err != nil {
		t.Fatal(err)
	}
	return db
}

func TestParseCanteenLocationFromName(t *testing.T) {
	cases := []struct {
		name   string
		area   string
		floor  string
		clean  string
	}{
		{"一食堂二楼 老麻抄手", CanteenLocationArea1, CanteenLocationFloor2, "老麻抄手"},
		{"二食堂一楼麻辣香锅", CanteenLocationArea2, CanteenLocationFloor1, "麻辣香锅"},
		{"麻辣烫（一食堂2楼）", CanteenLocationArea1, CanteenLocationFloor2, "麻辣烫"},
		{"第一食堂-二层小炒", CanteenLocationArea1, CanteenLocationFloor2, "小炒"},
		{"老麻抄手", "", "", "老麻抄手"},
		{"一食堂", CanteenLocationArea1, "", ""},
		{"2号食堂1F面馆", CanteenLocationArea2, CanteenLocationFloor1, "面馆"},
		{"一食堂二楼二楼面馆", CanteenLocationArea1, CanteenLocationFloor2, "面馆"},
	}
	for _, c := range cases {
		area, floor, cleaned := parseCanteenLocationFromName(c.name)
		if area != c.area || floor != c.floor || cleaned != c.clean {
			t.Errorf("parseCanteenLocationFromName(%q) = (%q, %q, %q), want (%q, %q, %q)",
				c.name, area, floor, cleaned, c.area, c.floor, c.clean)
		}
	}
}

func TestMigrateCanteenLocationsRenamesAndFillsLocation(t *testing.T) {
	db := newCanteenLocationTestDB(t)
	seed := []Canteen{
		{Name: "一食堂二楼 老麻抄手", NormalizedName: "一食堂二楼 老麻抄手", Verified: true, CreatedBy: 1},
		{Name: "二食堂一楼麻辣香锅", NormalizedName: "二食堂一楼麻辣香锅", Verified: true, CreatedBy: 1},
		{Name: "兰州拉面", NormalizedName: "兰州拉面", Verified: true, CreatedBy: 1},
		{Name: "一食堂", NormalizedName: "一食堂", Verified: true, CreatedBy: 1},
	}
	for i := range seed {
		if err := db.Create(&seed[i]).Error; err != nil {
			t.Fatal(err)
		}
	}

	if err := MigrateCanteenLocations(db); err != nil {
		t.Fatalf("migrate: %v", err)
	}

	var store1 Canteen
	if err := db.First(&store1, seed[0].ID).Error; err != nil {
		t.Fatal(err)
	}
	if store1.Name != "老麻抄手" || store1.LocationArea != CanteenLocationArea1 || store1.LocationFloor != CanteenLocationFloor2 {
		t.Fatalf("store1 = %q %q %q", store1.Name, store1.LocationArea, store1.LocationFloor)
	}
	if store1.NormalizedName != "老麻抄手" {
		t.Fatalf("store1 normalized = %q", store1.NormalizedName)
	}

	var store2 Canteen
	if err := db.First(&store2, seed[1].ID).Error; err != nil {
		t.Fatal(err)
	}
	if store2.Name != "麻辣香锅" || store2.LocationArea != CanteenLocationArea2 || store2.LocationFloor != CanteenLocationFloor1 {
		t.Fatalf("store2 = %q %q %q", store2.Name, store2.LocationArea, store2.LocationFloor)
	}

	// 无位置词的店保持原名，位置字段为空。
	var store3 Canteen
	if err := db.First(&store3, seed[2].ID).Error; err != nil {
		t.Fatal(err)
	}
	if store3.Name != "兰州拉面" || store3.LocationArea != "" || store3.LocationFloor != "" {
		t.Fatalf("store3 = %q %q %q", store3.Name, store3.LocationArea, store3.LocationFloor)
	}

	// 店名只有位置词时保留原名，但位置字段写入。
	var store4 Canteen
	if err := db.First(&store4, seed[3].ID).Error; err != nil {
		t.Fatal(err)
	}
	if store4.Name != "一食堂" || store4.LocationArea != CanteenLocationArea1 {
		t.Fatalf("store4 = %q %q %q", store4.Name, store4.LocationArea, store4.LocationFloor)
	}

	// 版本记录存在，重复执行幂等。
	var migration AppSchemaMigration
	if err := db.Where("version = ?", CanteenLocationMigrationVersion).First(&migration).Error; err != nil {
		t.Fatalf("migration version not recorded: %v", err)
	}
	if err := MigrateCanteenLocations(db); err != nil {
		t.Fatalf("re-migrate: %v", err)
	}
	var count int64
	if err := db.Model(&Canteen{}).Where("name = ?", "老麻抄手").Count(&count).Error; err != nil {
		t.Fatal(err)
	}
	if count != 1 {
		t.Fatalf("expected 1 老麻抄手 after re-migration, got %d", count)
	}
}

func TestMigrateCanteenLocationsKeepsOriginalNameOnConflict(t *testing.T) {
	db := newCanteenLocationTestDB(t)
	seed := []Canteen{
		// 两家解析后同名且同位置的店：后者保留原名避免混淆。
		{Name: "一食堂 老麻抄手", NormalizedName: "一食堂 老麻抄手", Verified: true, CreatedBy: 1},
		{Name: "老麻抄手（一食堂）", NormalizedName: "老麻抄手（一食堂）", Verified: true, CreatedBy: 1},
		// 同名但不同位置：复合唯一约束允许共存，均可改名。
		{Name: "二食堂 老麻抄手", NormalizedName: "二食堂 老麻抄手", Verified: true, CreatedBy: 1},
	}
	for i := range seed {
		if err := db.Create(&seed[i]).Error; err != nil {
			t.Fatal(err)
		}
	}

	if err := MigrateCanteenLocations(db); err != nil {
		t.Fatalf("migrate: %v", err)
	}

	var first Canteen
	if err := db.First(&first, seed[0].ID).Error; err != nil {
		t.Fatal(err)
	}
	if first.Name != "老麻抄手" || first.LocationArea != CanteenLocationArea1 {
		t.Fatalf("first = %q %q %q", first.Name, first.LocationArea, first.LocationFloor)
	}

	var second Canteen
	if err := db.First(&second, seed[1].ID).Error; err != nil {
		t.Fatal(err)
	}
	// 同名同位置撞名时保留原店名，但位置字段仍然写入。
	if second.Name != "老麻抄手（一食堂）" {
		t.Fatalf("conflict row renamed unexpectedly: %q", second.Name)
	}
	if second.LocationArea != CanteenLocationArea1 {
		t.Fatalf("conflict row missing location: %q", second.LocationArea)
	}

	var third Canteen
	if err := db.First(&third, seed[2].ID).Error; err != nil {
		t.Fatal(err)
	}
	if third.Name != "老麻抄手" || third.LocationArea != CanteenLocationArea2 {
		t.Fatalf("third = %q %q %q", third.Name, third.LocationArea, third.LocationFloor)
	}
}
