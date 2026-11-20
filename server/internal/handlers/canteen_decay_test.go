package handlers

import (
	"fmt"
	"testing"
	"time"

	"shenliyuan/internal/models"
)

// 两家店评价人数和星级完全一样，只是一家的评价都在两年前：
// 开启时间衰减后近期好评的店排在前面，预览能看到名次变化。
func TestTimeDecayRanksRecentPraiseAboveOldPraise(t *testing.T) {
	db := newCanteenTestDB(t)
	createCanteenTestUser(t, db, 1, "提交者")
	twoYearsAgo := time.Now().AddDate(-2, 0, 0)
	seed := func(name string, createdAt time.Time, userBase uint, created time.Time) models.Canteen {
		canteen := models.Canteen{Name: name, NormalizedName: name, Image: "/uploads/x.png", CreatedBy: 1, Verified: true, CreatedAt: created}
		if err := db.Create(&canteen).Error; err != nil {
			t.Fatal(err)
		}
		for i := uint(0); i < 6; i++ {
			createCanteenTestUser(t, db, userBase+i, fmt.Sprintf("u%d", userBase+i))
			if err := db.Create(&models.CanteenRating{CanteenID: canteen.ID, UserID: userBase + i, Star: 5, CreatedAt: createdAt}).Error; err != nil {
				t.Fatal(err)
			}
		}
		return canteen
	}
	// 老店创建得更晚：不开衰减时同分会按创建时间把它排在前面。
	recent := seed("近期好评店", time.Now(), 100, time.Now().Add(-time.Hour))
	old := seed("老好评店", twoYearsAgo, 200, time.Now())
	for i := uint(0); i < 3; i++ { // 中等分长尾，让全校均值低于 5
		mid := models.Canteen{Name: fmt.Sprintf("长尾%d", i), NormalizedName: fmt.Sprintf("长尾%d", i), Image: "/uploads/m.png", CreatedBy: 1, Verified: true}
		db.Create(&mid)
		for j := uint(0); j < 5; j++ {
			uid := 300 + i*10 + j
			createCanteenTestUser(t, db, uid, fmt.Sprintf("m%d", uid))
			db.Create(&models.CanteenRating{CanteenID: mid.ID, UserID: uid, Star: 3})
		}
	}

	rows, err := PreviewCanteenDecayRanking(db)
	if err != nil {
		t.Fatal(err)
	}
	byID := map[uint]CanteenDecayPreviewRow{}
	for _, row := range rows {
		byID[row.ID] = row
	}
	if byID[old.ID].RankBefore != 1 || byID[recent.ID].RankBefore != 2 {
		t.Fatalf("before decay: old=%d recent=%d", byID[old.ID].RankBefore, byID[recent.ID].RankBefore)
	}
	if byID[recent.ID].RankAfter != 1 || byID[old.ID].RankAfter != 2 {
		t.Fatalf("after decay: recent=%d old=%d", byID[recent.ID].RankAfter, byID[old.ID].RankAfter)
	}
	if byID[old.ID].ScoreAfter >= byID[old.ID].ScoreBefore {
		t.Fatalf("old praise score should shrink toward the mean: %v -> %v", byID[old.ID].ScoreBefore, byID[old.ID].ScoreAfter)
	}
}
