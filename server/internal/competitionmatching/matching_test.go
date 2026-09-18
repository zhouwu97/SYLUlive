package competitionmatching

import (
	"testing"
	"time"
)

func testNow() time.Time {
	return time.Date(2026, 9, 18, 10, 0, 0, 0, time.UTC)
}

func baseCandidate() Candidate {
	start := testNow().AddDate(0, 1, 0)
	end := start.AddDate(0, 0, 20)
	return Candidate{
		ID:                         1,
		CompetitionID:              "NAT-001",
		CatalogOrder:               1,
		Tags:                       []string{},
		RiskTags:                   []string{},
		Rating:                     "B+",
		TimeStatus:                 "confirmed",
		EventStart:                 &start,
		RegistrationEnd:            &end,
		PersonalizedRankingAllowed: true,
	}
}

func candidateWithMajors(values ...string) Candidate {
	candidate := baseCandidate()
	candidate.ClusterScope = ResolveEventMajors(values)
	return candidate
}

func userWithMajor(major string) ResolvedUser {
	return ResolveUser(UserProfile{Major: major, College: "信息科学与工程学院", EntryYear: "2023"})
}

// —— 词表与映射 ——

func TestNormalizeMajorStripsParentheticalSuffix(t *testing.T) {
	cases := map[string]string{
		"计算机科学与技术（嵌入式）": "计算机科学与技术",
		"计算机科学与技术(嵌入式)": "计算机科学与技术",
		" 软件工程 ":        "软件工程",
		"计算机科学与技术":      "计算机科学与技术",
	}
	for input, want := range cases {
		if got := NormalizeMajor(input); got != want {
			t.Fatalf("NormalizeMajor(%q)=%q want %q", input, got, want)
		}
	}
}

func TestLookupMajorClustersCoversMainstreamMajors(t *testing.T) {
	// 这三个专业在旧实现下的召回为 0，是本次故障的重灾区，必须有映射。
	cases := map[string][]Cluster{
		"计算机科学与技术":    {"计算机类"},
		"自动化":         {"自动化类", "自动化相关"},
		"机械设计制造及其自动化": {"机械类", "工程设计相关"},
	}
	for major, want := range cases {
		got, mapped := LookupMajorClusters(major)
		if !mapped {
			t.Fatalf("专业 %q 未映射，会导致该专业永远匹配不到", major)
		}
		if len(got) != len(want) {
			t.Fatalf("专业 %q 映射=%v want %v", major, got, want)
		}
		for index := range want {
			if got[index] != want[index] {
				t.Fatalf("专业 %q 映射=%v want %v", major, got, want)
			}
		}
	}
}

func TestLookupMajorClustersResolvesAliasAndBroadFallback(t *testing.T) {
	clusters, mapped := LookupMajorClusters("计算机科学与技术专业")
	if !mapped || len(clusters) != 1 || clusters[0] != "计算机类" {
		t.Fatalf("别名未归一到标准专业名: %v", clusters)
	}
	// 名册外的专业靠粗归类兜底，避免静默落空。
	clusters, mapped = LookupMajorClusters("智能制造工程")
	if !mapped || len(clusters) == 0 {
		t.Fatal("未登记专业应能粗归类，否则覆盖率会出现隐性缺口")
	}
	if _, mapped := LookupMajorClusters("完全不知所云的专业"); mapped {
		t.Fatal("无法识别的专业必须返回 mapped=false，以便上报缺口")
	}
}

// —— 双向解析 ——

func TestResolveEventMajorsHandlesBothConventions(t *testing.T) {
	// 目录新包用簇标签。
	byCluster := ResolveEventMajors([]string{"计算机类", "软件工程"})
	if len(byCluster.Clusters) != 2 {
		t.Fatalf("簇标签解析失败: %+v", byCluster)
	}
	// legacy 数据用标准专业名，必须同样可解析。
	byMajor := ResolveEventMajors([]string{"计算机科学与技术"})
	if len(byMajor.Clusters) != 1 || byMajor.Clusters[0] != "计算机类" {
		t.Fatalf("标准专业名解析失败: %+v", byMajor)
	}
	if len(byMajor.ExactMajors) != 1 {
		t.Fatalf("精确专业全名应被保留以供加分: %+v", byMajor)
	}
	// 无法识别的标签必须可见，不允许静默丢弃（边界契约 B14）。
	unknown := ResolveEventMajors([]string{"某个自由文本方向"})
	if len(unknown.UnknownLabels) != 1 {
		t.Fatalf("未知标签必须登记: %+v", unknown)
	}
}

func TestResolveUserPrefersOverride(t *testing.T) {
	// 边界契约 B7：override 完全取代字典推断。
	user := ResolveUser(UserProfile{
		Major: "计算机科学与技术", College: "信息科学与工程学院",
		ClusterOverride: []string{"机械类"},
	})
	if !user.FromOverride || len(user.Clusters) != 1 || user.Clusters[0] != "机械类" {
		t.Fatalf("用户纠正未被优先采用: %+v", user)
	}
	// 非法 override 值被丢弃时不应把簇清空成错误状态。
	invalid := ResolveUser(UserProfile{Major: "计算机科学与技术", ClusterOverride: []string{"不存在的簇"}})
	if invalid.FromOverride {
		t.Fatal("全是非法值时不应标记为已使用 override")
	}
}

func TestResolveUserFlagsUnmappedMajor(t *testing.T) {
	// 边界契约 B1：无映射必须标记为缺口，而不是当成普通未命中。
	user := ResolveUser(UserProfile{Major: "完全不知所云的专业"})
	if !user.Unmapped {
		t.Fatal("无映射专业必须上报为缺口")
	}
}

// —— 打分核心：本次修复的回归测试 ——

func TestUnmatchedMajorIsDegradedNotDropped(t *testing.T) {
	// 这是本次故障的核心：赛事标注了专业范围但不命中用户专业时，
	// 旧实现直接丢弃（连通用池都进不去）。必须改为降级到 general_match。
	candidate := candidateWithMajors("机械类")
	result := Score(ScoreInput{
		Candidate: candidate, User: userWithMajor("计算机科学与技术"), Now: testNow(),
	})
	if result.GroupKey != GroupGeneralMatch {
		t.Fatalf("不命中的专业范围必须降级为通用候选，实际=%q", result.GroupKey)
	}
	if result.Tier == TierNone && result.Score == 0 {
		t.Fatal("降级后的赛事仍需有基础分值，否则等于被淘汰")
	}
	if result.Basis != BasisGeneral {
		t.Fatalf("依据应为 general，实际=%q", result.Basis)
	}
}

func TestClusterHitProducesMajorMatchAndTopScore(t *testing.T) {
	candidate := candidateWithMajors("计算机类", "软件工程")
	result := Score(ScoreInput{
		Candidate: candidate, User: userWithMajor("计算机科学与技术"), Now: testNow(),
	})
	if result.GroupKey != GroupMajorMatch || result.Basis != BasisMajorCluster {
		t.Fatalf("簇命中应进入专业直接相关组: %+v", result)
	}
	if result.Breakdown.Major != maxMajorScore {
		t.Fatalf("专业分应为 %d，实际 %d", maxMajorScore, result.Breakdown.Major)
	}
	if len(result.MatchedClusters) != 1 || result.MatchedClusters[0] != "计算机类" {
		t.Fatalf("命中簇记录错误: %v", result.MatchedClusters)
	}
}

func TestMultipleClusterHitsDoNotStack(t *testing.T) {
	// 边界契约 B2：多簇是精度手段而非加权手段。
	one := Score(ScoreInput{
		Candidate: candidateWithMajors("计算机类"), User: userWithMajor("计算机科学与技术"), Now: testNow(),
	})
	many := Score(ScoreInput{
		Candidate: candidateWithMajors("计算机类", "软件工程", "网络工程", "数据科学类"),
		User:      userWithMajor("计算机科学与技术"), Now: testNow(),
	})
	if one.Breakdown.Major != many.Breakdown.Major {
		t.Fatalf("多簇命中不应叠加专业分: %d vs %d", one.Breakdown.Major, many.Breakdown.Major)
	}
}

func TestBroadClusterIsDiscountedNotTreatedAsDirectMatch(t *testing.T) {
	// 宽口径标签（「数字媒体相关」等）命中不足以判定专业直接相关。
	candidate := candidateWithMajors("数字媒体相关")
	result := Score(ScoreInput{
		Candidate: candidate, User: userWithMajor("数字媒体艺术"), Now: testNow(),
	})
	if result.GroupKey == GroupMajorMatch {
		t.Fatal("宽口径标签不应进入专业直接相关组")
	}
	if result.Breakdown.Major >= maxMajorScore {
		t.Fatalf("宽口径标签必须降权，实际专业分=%d", result.Breakdown.Major)
	}
}

func TestExactMajorLabelAddsBonus(t *testing.T) {
	// 赛事直接标注用户的标准专业全名是最强精确信号。
	exact := Score(ScoreInput{
		Candidate: candidateWithMajors("计算机科学与技术"), User: userWithMajor("计算机科学与技术"), Now: testNow(),
	})
	clusterOnly := Score(ScoreInput{
		Candidate: candidateWithMajors("计算机类"), User: userWithMajor("计算机科学与技术"), Now: testNow(),
	})
	if exact.Breakdown.Major != clusterOnly.Breakdown.Major+maxExactMajorBonus {
		t.Fatalf("精确专业名应加 %d 分: %d vs %d", maxExactMajorBonus, exact.Breakdown.Major, clusterOnly.Breakdown.Major)
	}
	if exact.Breakdown.Major > maxMajorScore+maxExactMajorBonus {
		t.Fatalf("专业分超出上限: %d", exact.Breakdown.Major)
	}
}

func TestCollegeMatchWhenMajorNotHit(t *testing.T) {
	// 边界契约 B4：学院范围不命中同样只降级，不淘汰。
	candidate := candidateWithMajors("机械类")
	candidate.Colleges = []string{"信息科学与工程学院"}
	result := Score(ScoreInput{
		Candidate: candidate, User: userWithMajor("计算机科学与技术"), Now: testNow(),
	})
	if result.GroupKey != GroupCollegeMatch || result.Basis != BasisCollege {
		t.Fatalf("学院命中应进入学院相关组: %+v", result)
	}
	other := candidateWithMajors("机械类")
	other.Colleges = []string{"外国语学院"}
	degraded := Score(ScoreInput{
		Candidate: other, User: userWithMajor("计算机科学与技术"), Now: testNow(),
	})
	if degraded.GroupKey != GroupGeneralMatch {
		t.Fatal("学院也不命中时必须降级而不是丢弃")
	}
}

func TestGradeGateStillEliminates(t *testing.T) {
	// 边界契约 B6：年级是唯一保留的硬门，有明确排他语义。
	candidate := candidateWithMajors("计算机类")
	candidate.EntryYears = []string{"研究生"}
	result := Score(ScoreInput{
		Candidate: candidate, User: userWithMajor("计算机科学与技术"), Now: testNow(),
	})
	if result.GroupKey != "" || result.Tier != TierNone {
		t.Fatalf("年级不符必须淘汰: %+v", result)
	}
	// 未标注年级时放行，但维度标记为不限（边界契约 B5）。
	open := Score(ScoreInput{
		Candidate: candidateWithMajors("计算机类"), User: userWithMajor("计算机科学与技术"), Now: testNow(),
	})
	if open.Dimensions.Grade != DimUnrestricted {
		t.Fatalf("未标注年级应记为不限，实际=%q", open.Dimensions.Grade)
	}
}

func TestUnauthorizedCandidateIsMatchedButNotRankable(t *testing.T) {
	// 边界契约 B11（修正版）：授权只约束「是否参与排序」，
	// 不约束「是否计算匹配」。否则目录尚未普遍授权时（现状 310/310 为 false）
	// 匹配会整体失效，等于把功能关掉。
	candidate := candidateWithMajors("计算机类")
	candidate.PersonalizedRankingAllowed = false
	result := Score(ScoreInput{
		Candidate: candidate, User: userWithMajor("计算机科学与技术"), Now: testNow(),
	})
	if result.Rankable {
		t.Fatal("未授权赛事不得被标记为可个性化排序")
	}
	if result.GroupKey != GroupMajorMatch {
		t.Fatalf("未授权赛事仍应被正确分组，实际=%q", result.GroupKey)
	}
	if result.Breakdown.Major != maxMajorScore {
		t.Fatalf("未授权赛事仍应产出匹配事实，专业分=%d", result.Breakdown.Major)
	}
}

func TestScoreIsDeterministic(t *testing.T) {
	input := ScoreInput{
		Candidate: candidateWithMajors("计算机类", "软件工程"),
		User:      userWithMajor("计算机科学与技术"),
		Preference: Preference{
			Configured: true, Goals: []string{"ability"}, DirectionTags: []string{"程序设计"},
			WeeklyHours: 14, AcceptLongTermTraining: true,
		},
		Now: testNow(),
	}
	first := Score(input)
	for index := 0; index < 20; index++ {
		next := Score(input)
		if next.Score != first.Score || next.Basis != first.Basis || next.Tier != first.Tier {
			t.Fatalf("打分必须确定：%+v vs %+v", first, next)
		}
	}
}

func TestValueScoreCannotOutweighMajorMatch(t *testing.T) {
	// 治理要求：competition_rating 是人工评级，不得压过专业匹配。
	// 一个 S 级跨专业赛事，不得超越 C 级的专业直接相关赛事。
	crossMajor := candidateWithMajors("机械类")
	crossMajor.Rating = "S"
	crossMajor.ImportanceScore = 100
	crossMajorResult := Score(ScoreInput{
		Candidate: crossMajor, User: userWithMajor("计算机科学与技术"), Now: testNow(),
	})
	majorFit := candidateWithMajors("计算机类")
	majorFit.Rating = "C"
	majorFit.ImportanceScore = 10
	majorFitResult := Score(ScoreInput{
		Candidate: majorFit, User: userWithMajor("计算机科学与技术"), Now: testNow(),
	})
	if majorFitResult.Score <= crossMajorResult.Score {
		t.Fatalf("专业匹配必须压过人工评级: %d vs %d",
			majorFitResult.Score, crossMajorResult.Score)
	}
}

// —— 排序与治理回退 ——

func rankedFixture(id uint, order int, score int, basis string, authorized bool) Ranked {
	return Ranked{
		ID: id, CompetitionID: "NAT-" + string(rune('A'+id)), CatalogOrder: order,
		Rating: "B", Importance: 50,
		Result: Result{Score: score, Basis: basis, Rankable: authorized},
	}
}

func TestRankFallsBackToCatalogOrderWhenNothingAuthorized(t *testing.T) {
	// 治理断言：目录未授权时，顺序不得受画像或重要度影响。
	// 对应既有测试 TestCompetitionCandidateEngineUsesCatalogOrderWithoutImportanceOrDeadlinePriority。
	items := []Ranked{
		rankedFixture(2, 2, 0, BasisGeneral, false),
		rankedFixture(1, 1, 0, BasisGeneral, false),
	}
	items[0].Importance = 100
	items[1].Importance = 1
	ordered := Rank(items, RankOptions{PageSize: 20})
	if ordered[0].CatalogOrder != 1 || ordered[1].CatalogOrder != 2 {
		t.Fatalf("未授权时必须回退目录序: %+v", ordered)
	}
}

func TestRankOrdersAuthorizedByScoreAndSinksUnauthorized(t *testing.T) {
	items := []Ranked{
		rankedFixture(1, 1, 20, BasisGeneral, false),
		rankedFixture(2, 2, 90, BasisMajorCluster, true),
		rankedFixture(3, 3, 60, BasisMajorCluster, true),
	}
	ordered := Rank(items, RankOptions{PageSize: 20, ExplorePositions: []int{}})
	if ordered[0].ID != 2 || ordered[1].ID != 3 || ordered[2].ID != 1 {
		t.Fatalf("授权赛事应按分值排序、未授权赛事沉底: %+v", ordered)
	}
}

func TestRankUsesStableTieBreakers(t *testing.T) {
	left := rankedFixture(5, 3, 50, BasisMajorCluster, true)
	right := rankedFixture(4, 3, 50, BasisMajorCluster, true)
	left.CompetitionID, right.CompetitionID = "NAT-X", "NAT-X"
	ordered := Rank([]Ranked{left, right}, RankOptions{PageSize: 20, ExplorePositions: []int{}})
	if ordered[0].ID != 4 {
		t.Fatalf("二级键全等时应按主键升序兜底: %+v", ordered)
	}
}

func TestRankInjectsExplorationSlotsFromGeneralPool(t *testing.T) {
	items := make([]Ranked, 0, 30)
	// 前 20 条全是专业直接命中，分值递减。
	for index := 0; index < 20; index++ {
		item := rankedFixture(uint(index+1), index+1, 90-index, BasisMajorCluster, true)
		item.Rating = "C"
		items = append(items, item)
	}
	// 池外放一条高价值通用赛事，它应该被探索槽捞回来。
	star := rankedFixture(99, 99, 20, BasisGeneral, true)
	star.Rating = "S"
	items = append(items, star)

	ordered := Rank(items, RankOptions{PageSize: 20})
	found := -1
	for index, item := range ordered[:20] {
		if item.ID == star.ID {
			found = index
		}
	}
	if found < 0 {
		t.Fatal("高价值跨专业赛事未被探索槽捞回，会形成过滤气泡")
	}
	if found != DefaultExplorePositions[0] && found != DefaultExplorePositions[1] && found != DefaultExplorePositions[2] {
		t.Fatalf("探索槽位置应为 %v 之一，实际 %d", DefaultExplorePositions, found)
	}
	if len(ordered) != len(items) {
		t.Fatalf("探索槽不得改变总条数: %d vs %d", len(ordered), len(items))
	}
}

func TestRankExplorationPreservesPageSize(t *testing.T) {
	items := make([]Ranked, 0, 25)
	for index := 0; index < 25; index++ {
		basis := BasisMajorCluster
		if index >= 20 {
			basis = BasisGeneral
		}
		items = append(items, rankedFixture(uint(index+1), index+1, 90-index, basis, true))
	}
	ordered := Rank(items, RankOptions{PageSize: 20})
	if len(ordered) != 25 {
		t.Fatalf("排序不得丢失或复制条目: %d", len(ordered))
	}
	seen := map[uint]struct{}{}
	for _, item := range ordered {
		if _, exists := seen[item.ID]; exists {
			t.Fatalf("条目 %d 重复出现", item.ID)
		}
		seen[item.ID] = struct{}{}
	}
}

func TestRankIsDeterministic(t *testing.T) {
	items := make([]Ranked, 0, 30)
	for index := 0; index < 30; index++ {
		basis := BasisMajorCluster
		if index%3 == 0 {
			basis = BasisGeneral
		}
		items = append(items, rankedFixture(uint(index+1), index+1, 80-(index%10), basis, true))
	}
	first := Rank(items, RankOptions{PageSize: 20})
	for round := 0; round < 10; round++ {
		next := Rank(items, RankOptions{PageSize: 20})
		for index := range first {
			if first[index].ID != next[index].ID {
				t.Fatalf("排序必须确定：第 %d 位 %d vs %d", index, first[index].ID, next[index].ID)
			}
		}
	}
}
