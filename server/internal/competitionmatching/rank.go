package competitionmatching

import (
	"sort"
)

// Ranked 是参与排序的条目。
type Ranked struct {
	ID            uint
	CompetitionID string
	CatalogOrder  int
	Rating        string
	Importance    int
	Result        Result
}

// RankOptions 控制排序与探索槽行为。
type RankOptions struct {
	// PageSize 为首页长度；探索槽只作用于首页。
	PageSize int
	// ExplorePositions 是探索槽的 0 基下标。
	// 默认 {7, 12, 18} —— 避开头部，约 15%，与 FEED-5 的 3/20 一致。
	ExplorePositions []int
}

// DefaultExplorePositions 是设计约定的探索槽位置。
var DefaultExplorePositions = []int{7, 12, 18}

// Rank 产出最终顺序。纯函数：同一输入必然得到同一输出。
//
// 治理约束（不可绕过）：
//   - 若没有任何赛事被授权个性化排序，则整体回退纯目录序，
//     保证既有测试所断言的「重要度与截止不得改变目录序」继续成立。
//   - 未授权赛事即使出现在有授权的结果集中，也不参与打分排序，
//     按其目录序位置排在已授权赛事之后。
//   - 探索槽只从已授权且「非专业直接命中」的赛事中选取。未授权条目保持目录序。
//     原因：专业匹配强的用户
//     其 major_match 池已足够大，跨专业的高价值赛事（如 eligible_majors
//     为空的挑战杯）会被压到很后面，形成过滤气泡。
func Rank(items []Ranked, options RankOptions) []Ranked {
	if len(items) == 0 {
		return []Ranked{}
	}
	pageSize := options.PageSize
	if pageSize <= 0 {
		pageSize = 20
	}
	positions := options.ExplorePositions
	if positions == nil {
		positions = DefaultExplorePositions
	}

	authorized := make([]Ranked, 0, len(items))
	unauthorized := make([]Ranked, 0, len(items))
	for _, item := range items {
		if item.Result.Rankable {
			authorized = append(authorized, item)
			continue
		}
		unauthorized = append(unauthorized, item)
	}

	// 无任何授权赛事：完全回退目录序，不做任何打分排序。
	if len(authorized) == 0 {
		sortByCatalogOrder(unauthorized)
		return unauthorized
	}

	sort.SliceStable(authorized, func(i, j int) bool {
		return authorizedLess(authorized[i], authorized[j])
	})
	sortByCatalogOrder(unauthorized)

	ordered := make([]Ranked, 0, len(items))
	ordered = append(ordered, authorized...)
	ordered = append(ordered, unauthorized...)

	return applyExploration(ordered, pageSize, positions)
}

// authorizedLess 是已授权赛事的排序比较链。
// 顺序：分值 → 人工评级 → 重要度 → 目录序 → 赛事编号 → 主键。
// 最后三级保证全序，杜绝不稳定排序。
func authorizedLess(left, right Ranked) bool {
	if left.Result.Score != right.Result.Score {
		return left.Result.Score > right.Result.Score
	}
	leftRank, rightRank := ratingRank(left.Rating), ratingRank(right.Rating)
	if leftRank != rightRank {
		return leftRank > rightRank
	}
	if left.Importance != right.Importance {
		return left.Importance > right.Importance
	}
	if left.CatalogOrder != right.CatalogOrder {
		return left.CatalogOrder < right.CatalogOrder
	}
	if left.CompetitionID != right.CompetitionID {
		return left.CompetitionID < right.CompetitionID
	}
	return left.ID < right.ID
}

func sortByCatalogOrder(items []Ranked) {
	sort.SliceStable(items, func(i, j int) bool {
		if items[i].CatalogOrder != items[j].CatalogOrder {
			return items[i].CatalogOrder < items[j].CatalogOrder
		}
		if items[i].CompetitionID != items[j].CompetitionID {
			return items[i].CompetitionID < items[j].CompetitionID
		}
		return items[i].ID < items[j].ID
	})
}

// applyExploration 在首页插入探索槽。
//
// 探索源：首页之外、且匹配依据不是专业直接命中的赛事。
// 这些正是「应该被看到但被专业匹配压下去」的跨专业高价值赛事。
// 探索槽不参与打分排序，直接按价值评级占位。
func applyExploration(ordered []Ranked, pageSize int, positions []int) []Ranked {
	if pageSize >= len(ordered) || len(positions) == 0 {
		return ordered
	}
	page := append([]Ranked(nil), ordered[:pageSize]...)
	rest := append([]Ranked(nil), ordered[pageSize:]...)

	pool := make([]Ranked, 0, len(rest))
	for _, item := range rest {
		// 只从 general_match 取探索源：这些是没有专业指向的通用池赛事，
		// 也正是被专业匹配压下去的那批跨专业高价值赛事。治理要求未授权条目
		// 的目录位置不受画像或探索策略影响。
		if !item.Result.Rankable || item.Result.Basis != BasisGeneral {
			continue
		}
		pool = append(pool, item)
	}
	if len(pool) == 0 {
		return ordered
	}
	sort.SliceStable(pool, func(i, j int) bool {
		leftRank, rightRank := ratingRank(pool[i].Rating), ratingRank(pool[j].Rating)
		if leftRank != rightRank {
			return leftRank > rightRank
		}
		if pool[i].Importance != pool[j].Importance {
			return pool[i].Importance > pool[j].Importance
		}
		return pool[i].CatalogOrder < pool[j].CatalogOrder
	})

	// 先一次性确定探索候选，再组装首页。逐个 insert 会把先插入的候选
	// 推到后续位置并在最后一次插入时挤出首页，导致 3 个槽位只剩 2 个。
	validPositions := make([]int, 0, len(positions))
	seenPositions := make(map[int]struct{}, len(positions))
	for _, position := range positions {
		if position >= 0 && position < pageSize {
			if _, exists := seenPositions[position]; !exists {
				seenPositions[position] = struct{}{}
				validPositions = append(validPositions, position)
			}
		}
	}
	if len(validPositions) > len(pool) {
		validPositions = validPositions[:len(pool)]
	}
	selected := pool[:len(validPositions)]
	selectedIDs := make(map[uint]struct{}, len(selected))
	for _, item := range selected {
		selectedIDs[item.ID] = struct{}{}
	}
	originalPage := page
	page = make([]Ranked, 0, pageSize)
	selectedByPosition := make(map[int]Ranked, len(selected))
	for index, position := range validPositions {
		selectedByPosition[position] = selected[index]
	}
	pageCursor := 0
	for index := 0; index < pageSize; index++ {
		if item, ok := selectedByPosition[index]; ok {
			page = append(page, item)
			continue
		}
		page = append(page, originalPage[pageCursor])
		pageCursor++
	}
	displaced := append([]Ranked(nil), originalPage[pageCursor:]...)
	nextRest := make([]Ranked, 0, len(rest)+len(displaced))
	nextRest = append(nextRest, displaced...)
	for _, item := range rest {
		if _, selected := selectedIDs[item.ID]; !selected {
			nextRest = append(nextRest, item)
		}
	}
	rest = nextRest

	result := make([]Ranked, 0, len(ordered))
	result = append(result, page...)
	result = append(result, rest...)
	return result
}

// removeByID 摘除指定条目，保持其余条目顺序不变。
func removeByID(items []Ranked, id uint) []Ranked {
	result := make([]Ranked, 0, len(items))
	removed := false
	for _, item := range items {
		if !removed && item.ID == id {
			removed = true
			continue
		}
		result = append(result, item)
	}
	return result
}

// insertAt 在首页指定位置插入条目，被挤出首页的条目回到后续序列头部。
// 该操作保持首页长度不变，因此探索槽不会改变分页语义。
func insertAt(page []Ranked, rest []Ranked, position int, item Ranked) ([]Ranked, []Ranked) {
	expanded := make([]Ranked, 0, len(page)+1)
	expanded = append(expanded, page[:position]...)
	expanded = append(expanded, item)
	expanded = append(expanded, page[position:]...)
	displaced := expanded[len(page)]
	nextPage := expanded[:len(page)]
	nextRest := make([]Ranked, 0, len(rest)+1)
	nextRest = append(nextRest, displaced)
	nextRest = append(nextRest, rest...)
	return nextPage, nextRest
}

// CatalogAllowsPersonalizedRanking 判断结果集是否整体允许个性化排序。
// 与既有引擎的聚合语义一致：任一赛事授权即视为授权。
func CatalogAllowsPersonalizedRanking(items []Ranked) bool {
	for _, item := range items {
		if item.Result.Rankable {
			return true
		}
	}
	return false
}
