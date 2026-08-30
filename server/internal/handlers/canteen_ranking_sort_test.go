package handlers

import "testing"

func makeRankingEntry(id uint, star float64, count int, score float64) canteenRankingEntry {
	e := canteenRankingEntry{}
	e.ID = id
	e.AverageStar = star
	e.RatingCount = count
	e.RankingScore = score
	return e
}

// rating 模式倒序展示：星级低→高，同星级评价人数少→多，无评价置后。
func TestSortRankingRatingAscending(t *testing.T) {
	entries := []canteenRankingEntry{
		makeRankingEntry(1, 5.0, 3, 86),
		makeRankingEntry(2, 5.0, 1, 82),
		makeRankingEntry(3, 4.0, 9, 78),
		makeRankingEntry(4, 5.0, 2, 84),
		makeRankingEntry(5, 0, 0, 0),
	}
	sortRanking(entries, "rating")

	want := []uint{3, 2, 4, 1, 5}
	for i, w := range want {
		if entries[i].ID != w {
			t.Fatalf("rating 倒序位置 %d: got id=%d want id=%d", i+1, entries[i].ID, w)
		}
		if entries[i].Rank != i+1 {
			t.Fatalf("位置 %d rank 赋值错误: got %d", i+1, entries[i].Rank)
		}
	}
}

// composite 模式保持高分在前，不受 rating 倒序影响。
func TestSortRankingCompositeUnchanged(t *testing.T) {
	entries := []canteenRankingEntry{
		makeRankingEntry(1, 5.0, 1, 4.1),
		makeRankingEntry(2, 5.0, 3, 4.3),
		makeRankingEntry(3, 4.0, 9, 3.9),
	}
	sortRanking(entries, "composite")

	want := []uint{2, 1, 3}
	for i, w := range want {
		if entries[i].ID != w {
			t.Fatalf("composite 排序位置 %d: got id=%d want id=%d", i+1, entries[i].ID, w)
		}
	}
}
