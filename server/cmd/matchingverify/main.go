// Command matchingverify 用与线上完全相同的匹配代码离线复算真实目录快照。
//
// 存在的理由：打分逻辑被抽成纯函数包后，可以脱离数据库与 HTTP 复算，
// 因此离线结果与线上结果必然一致——不存在「离线脚本另写一套逻辑」的漂移风险。
// 这是 docs/plans/competition-recommendation-plan.md §10.3 要求的覆盖率审计工具。
//
// 用法：
//
//	go run ./cmd/matchingverify -catalog ../tmp/competition-schedule/public-events.json
package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"sort"
	"strings"
	"time"

	"shenliyuan/internal/competitionmatching"
)

type catalogItem struct {
	ID                         uint     `json:"id"`
	CompetitionID              string   `json:"competition_id"`
	CatalogOrder               int      `json:"catalog_order"`
	Title                      string   `json:"title"`
	EligibleMajors             []string `json:"eligible_majors"`
	EligibleColleges           []string `json:"eligible_colleges"`
	EligibleEntryYears         []string `json:"eligible_entry_years"`
	Tags                       []string `json:"tags"`
	RiskTags                   []string `json:"risk_tags"`
	CompetitionRating          string   `json:"competition_rating"`
	ImportanceScore            int      `json:"importance_score"`
	SchoolRecognitionStatus    string   `json:"school_recognition_status"`
	TimeStatus                 string   `json:"time_status"`
	EvidenceSubgrade           string   `json:"evidence_subgrade"`
	ParticipationType          string   `json:"participation_type"`
	TeamSizeMin                int      `json:"team_size_min"`
	TeamSizeMax                int      `json:"team_size_max"`
	PersonalizedRankingAllowed bool     `json:"personalized_ranking_allowed"`
	PrimaryCategory            *struct {
		Slug string `json:"slug"`
	} `json:"primary_category"`
	RegistrationEnd *time.Time `json:"registration_end"`
	EventStart      *time.Time `json:"event_start"`
}

type catalogFile struct {
	Total int           `json:"total"`
	Items []catalogItem `json:"items"`
}

// 待验证的画像：覆盖四类代表学院，用于检查召回是否均衡。
var probes = []struct {
	name    string
	major   string
	college string
}{
	{"计算机科学与技术", "计算机科学与技术", "信息科学与工程学院"},
	{"软件工程", "软件工程", "信息科学与工程学院"},
	{"自动化", "自动化", "自动化与电气工程学院"},
	{"机械设计制造及其自动化", "机械设计制造及其自动化", "机械工程学院"},
	{"工业设计", "工业设计", "艺术设计学院"},
	{"环境设计", "环境设计", "艺术设计学院"},
	{"会计学", "会计学", "经济管理学院"},
	{"英语", "英语", "外国语学院"},
}

func main() {
	catalogPath := flag.String("catalog", "", "目录快照 JSON 路径")
	entryYear := flag.String("year", "2023", "入学年份")
	assumeAuthorized := flag.Bool("assume-authorized", false,
		"模拟目录已授权个性化排序（用于评估阶段 2 翻转 personalized_ranking_allowed 后的预期效果）")
	audit := flag.Bool("audit", false,
		"输出覆盖率审计报告：簇引用分布、无专业映射的簇、未识别标签、宽口径标签分布、疑似标签错配")
	flag.Parse()
	if *catalogPath == "" {
		fmt.Fprintln(os.Stderr, "必须指定 -catalog")
		os.Exit(2)
	}
	raw, err := os.ReadFile(*catalogPath)
	if err != nil {
		fmt.Fprintf(os.Stderr, "读取目录失败: %v\n", err)
		os.Exit(1)
	}
	var catalog catalogFile
	if err := json.Unmarshal(raw, &catalog); err != nil {
		fmt.Fprintf(os.Stderr, "解析目录失败: %v\n", err)
		os.Exit(1)
	}
	now := time.Now()
	items := catalog.Items

	candidates := make([]competitionmatching.Candidate, 0, len(items))
	unknownLabels := map[string]int{}
	for _, item := range items {
		scope := competitionmatching.ResolveEventMajors(item.EligibleMajors)
		for _, label := range scope.UnknownLabels {
			unknownLabels[label]++
		}
		slug := ""
		if item.PrimaryCategory != nil {
			slug = item.PrimaryCategory.Slug
		}
		candidates = append(candidates, competitionmatching.Candidate{
			ID: item.ID, CompetitionID: item.CompetitionID, CatalogOrder: item.CatalogOrder,
			ClusterScope: scope, Colleges: item.EligibleColleges, EntryYears: item.EligibleEntryYears,
			Tags: item.Tags, CategorySlug: slug, RiskTags: item.RiskTags,
			Rating: item.CompetitionRating, ImportanceScore: item.ImportanceScore,
			SchoolRecognitionStatus: item.SchoolRecognitionStatus,
			TimeStatus:              item.TimeStatus, RegistrationEnd: item.RegistrationEnd,
			EventStart: item.EventStart, EvidenceSubgrade: item.EvidenceSubgrade,
			ParticipationType: item.ParticipationType, TeamSizeMin: item.TeamSizeMin,
			TeamSizeMax:                item.TeamSizeMax,
			PersonalizedRankingAllowed: item.PersonalizedRankingAllowed || *assumeAuthorized,
		})
	}

	if *audit {
		printCoverageAudit(items, candidates, unknownLabels)
		return
	}

	fmt.Printf("算法版本: %s\n", competitionmatching.AlgorithmVersion)
	fmt.Printf("目录赛事数: %d（快照声明 %d）\n", len(candidates), catalog.Total)
	if *assumeAuthorized {
		fmt.Println("排序授权: 已按 -assume-authorized 模拟全部授权（阶段 2 预期态）")
	} else {
		fmt.Printf("排序授权: 按目录实际值（%d/%d 条授权）\n", authorizedCount(items), len(items))
	}
	fmt.Println()

	fmt.Println("=== 召回分布（未命中的专业范围是否被淘汰）===")
	fmt.Printf("%-24s %8s %8s %8s %8s %8s\n", "专业", "专业相关", "学院相关", "通用", "被淘汰", "合计")
	totals := map[string]int{}
	for _, probe := range probes {
		user := competitionmatching.ResolveUser(competitionmatching.UserProfile{
			Major: probe.major, College: probe.college, EntryYear: *entryYear,
		})
		if user.Unmapped {
			fmt.Printf("%-24s  ⚠ 专业无映射，映射缺口需修复\n", probe.name)
			continue
		}
		counts := map[string]int{}
		dropped := 0
		for _, candidate := range candidates {
			result := competitionmatching.Score(competitionmatching.ScoreInput{
				Candidate: candidate, User: user, Now: now,
			})
			if result.GroupKey == "" {
				dropped++
				continue
			}
			counts[result.GroupKey]++
		}
		kept := counts["major_match"] + counts["college_match"] + counts["general_match"]
		totals[probe.name] = counts["major_match"]
		fmt.Printf("%-24s %8d %8d %8d %8d %8d\n",
			probe.name, counts["major_match"], counts["college_match"], counts["general_match"], dropped, kept)
	}

	fmt.Println("\n=== 召回均衡度（专业直接相关的最大/最小比）===")
	values := make([]int, 0, len(totals))
	for _, value := range totals {
		values = append(values, value)
	}
	sort.Ints(values)
	if len(values) > 0 && values[0] > 0 {
		fmt.Printf("最小 %d，最大 %d，比值 %.2f（验收阈值为 ≤ 1.30）\n",
			values[0], values[len(values)-1], float64(values[len(values)-1])/float64(values[0]))
	} else {
		fmt.Printf("最小值 %d —— 存在专业完全无专业相关召回，未达标\n", values[0])
	}

	fmt.Println("\n=== 覆盖率（被至少一次推荐命中的赛事占比）===")
	for _, probe := range probes {
		user := competitionmatching.ResolveUser(competitionmatching.UserProfile{
			Major: probe.major, College: probe.college, EntryYear: *entryYear,
		})
		if user.Unmapped {
			continue
		}
		ranked := make([]competitionmatching.Ranked, 0, len(candidates))
		for _, candidate := range candidates {
			result := competitionmatching.Score(competitionmatching.ScoreInput{
				Candidate: candidate, User: user, Now: now,
			})
			if result.GroupKey == "" {
				continue
			}
			ranked = append(ranked, competitionmatching.Ranked{
				ID: candidate.ID, CompetitionID: candidate.CompetitionID,
				CatalogOrder: candidate.CatalogOrder, Rating: candidate.Rating,
				Importance: candidate.ImportanceScore, Result: result,
			})
		}
		ordered := competitionmatching.Rank(ranked, competitionmatching.RankOptions{PageSize: 20})
		top10Major := 0
		for index := 0; index < 10 && index < len(ordered); index++ {
			if ordered[index].Result.Basis == competitionmatching.BasisMajorCluster {
				top10Major++
			}
		}
		fmt.Printf("  %-24s 候选 %3d  首屏专业相关占比 %d/10\n", probe.name, len(ordered), top10Major)
	}

	fmt.Println("\n=== 目录侧未识别标签（须逐项登记，对应边界契约 B14）===")
	if len(unknownLabels) == 0 {
		fmt.Println("  无")
	} else {
		keys := make([]string, 0, len(unknownLabels))
		for key := range unknownLabels {
			keys = append(keys, key)
		}
		sort.Strings(keys)
		for _, key := range keys {
			fmt.Printf("  %-24s 出现 %d 次\n", key, unknownLabels[key])
		}
	}

	fmt.Println("\n=== 确定性自检 ===")
	user := competitionmatching.ResolveUser(competitionmatching.UserProfile{
		Major: "计算机科学与技术", College: "信息科学与工程学院", EntryYear: *entryYear,
	})
	first := rankIDs(candidates, user, now)
	stable := true
	for round := 0; round < 5; round++ {
		next := rankIDs(candidates, user, now)
		for index := range first {
			if first[index] != next[index] {
				stable = false
				break
			}
		}
	}
	if stable {
		fmt.Printf("  5 次重复计算顺序完全一致（%d 条）\n", len(first))
	} else {
		fmt.Println("  ✗ 顺序不稳定，违反确定性要求")
	}
}

func authorizedCount(items []catalogItem) int {
	count := 0
	for _, item := range items {
		if item.PersonalizedRankingAllowed {
			count++
		}
	}
	return count
}

// truncate 按字符截断长标题，保证审计输出在终端里可读。
func truncate(value string, limit int) string {
	runes := []rune(strings.TrimSpace(value))
	if len(runes) <= limit {
		return string(runes)
	}
	return string(runes[:limit]) + "…"
}

// mismatchRule 是「赛事名称里的学科词 → 应当出现的专业簇」。
//
// 用途只有一个：把人工复核从「逐条读 310 条」变成「只读被标出来的那几条」。
// 刻意做得保守——只在标题命中了明确的学科词、而 eligible_majors 与预期簇**完全无交集**时
// 才列为疑似错配；命中不了任何关键词的赛事直接跳过，不产生噪声。
type mismatchRule struct {
	keyword string
	// excluded 用于挡住复合词误命中：例如「程序设计」「电子设计」都含「设计」，
	// 但它们指向的是计算机与电子信息方向，不是艺术设计。
	excluded []string
	expected []competitionmatching.Cluster
}

var expectedClustersByKeyword = []mismatchRule{
	{"化学", nil, []competitionmatching.Cluster{"化学工程与工艺", "应用化学", "化学相关", "材料类", "生命健康相关"}},
	{"化工", nil, []competitionmatching.Cluster{"化学工程与工艺", "应用化学", "化学相关", "材料类", "生命健康相关"}},
	{"数学", nil, []competitionmatching.Cluster{"数学类", "数学与应用数学", "统计学类", "数据科学类"}},
	{"会计", nil, []competitionmatching.Cluster{"会计学", "财务管理", "工商管理类"}},
	{"财务", nil, []competitionmatching.Cluster{"会计学", "财务管理", "工商管理类"}},
	{"金融", nil, []competitionmatching.Cluster{"金融学", "经济学类", "国际经济与贸易", "工商管理类"}},
	{"机械", nil, []competitionmatching.Cluster{"机械类", "车辆工程", "工业设计", "材料成型及控制工程", "工程设计相关", "工科相关专业"}},
	{"车辆", nil, []competitionmatching.Cluster{"车辆工程", "机械类", "工科相关专业"}},
	{"汽车", nil, []competitionmatching.Cluster{"车辆工程", "机械类", "工科相关专业"}},
	{"电子", []string{"电子商务", "电子数据"}, []competitionmatching.Cluster{"电子信息类", "通信工程", "集成电路相关", "微电子相关", "自动化类", "机器人工程"}},
	{"光电", nil, []competitionmatching.Cluster{"电子信息类", "工科相关专业"}},
	{"芯片", nil, []competitionmatching.Cluster{"集成电路相关", "微电子相关", "电子信息类"}},
	{"集成电路", nil, []competitionmatching.Cluster{"集成电路相关", "微电子相关", "电子信息类"}},
	{"电气", nil, []competitionmatching.Cluster{"电气工程类", "自动化类", "工科相关专业"}},
	{"计算机", nil, []competitionmatching.Cluster{"计算机类", "软件工程", "网络工程", "数据科学类", "智能科学类"}},
	{"软件", nil, []competitionmatching.Cluster{"软件工程", "计算机类", "网络工程", "数据科学类"}},
	{"算法", nil, []competitionmatching.Cluster{"计算机类", "软件工程", "数据科学类", "数学类"}},
	{"人工智能", nil, []competitionmatching.Cluster{"智能科学类", "计算机类", "数据科学类", "电子信息类"}},
	{"材料", nil, []competitionmatching.Cluster{"材料类", "金属材料工程相关", "材料成型及控制工程"}},
	{"环境", nil, []competitionmatching.Cluster{"环境工程", "化学工程与工艺", "应用化学", "工科相关专业"}},
	{"机器人", nil, []competitionmatching.Cluster{"机器人工程", "自动化类", "机械类", "电子信息类", "计算机类"}},
	{"物联网", nil, []competitionmatching.Cluster{"计算机类", "网络工程", "电子信息类", "通信工程", "数据科学类"}},
	{"物流", nil, []competitionmatching.Cluster{"物流管理相关", "管理科学与工程类", "工商管理类"}},
	{"英语", nil, []competitionmatching.Cluster{"英语", "翻译", "人文社科相关", "国际交流相关"}},
	{"翻译", nil, []competitionmatching.Cluster{"翻译", "英语", "俄语", "人文社科相关", "国际交流相关"}},
	{"俄语", nil, []competitionmatching.Cluster{"俄语", "翻译", "人文社科相关", "国际交流相关"}},
	{"设计", []string{
		"程序设计", "电子设计", "机械设计", "结构设计", "系统设计", "电路设计",
		"集成电路设计", "电气设计", "车辆设计", "交通设计", "仿真设计", "算法设计",
		"智能设计", "外观设计", "网站设计", "电路与系统设计",
		"物联网设计", "机器人设计", "软件设计", "网络设计", "通信设计",
		"光电设计", "物流设计", "商业设计", "汽车设计", "能源设计",
	}, []competitionmatching.Cluster{"视觉传达设计", "环境设计", "产品设计", "动画", "数字媒体相关", "工业设计"}},
	{"艺术", nil, []competitionmatching.Cluster{"视觉传达设计", "环境设计", "产品设计", "动画", "数字媒体相关", "工业设计"}},
	{"动画", nil, []competitionmatching.Cluster{"动画", "数字媒体相关", "视觉传达设计"}},
	{"医学", nil, []competitionmatching.Cluster{"生命健康相关"}},
	{"药", nil, []competitionmatching.Cluster{"化学工程与工艺", "应用化学", "生命健康相关"}},
}

// printCoverageAudit 输出覆盖率审计报告（计划 §10.3）。
//
// 这份报告是阶段 1 验收的直接证据，也是交给学院教务员核对映射表的输入。
// 关键设计：判定全部复用 competitionmatching 的同一份词表与解析函数，
// 因此报告里的「无映射」「未识别」与线上匹配的口径必然一致。
func printCoverageAudit(items []catalogItem, candidates []competitionmatching.Candidate, unknownLabels map[string]int) {
	fmt.Printf("算法版本: %s\n", competitionmatching.AlgorithmVersion)
	fmt.Printf("目录赛事数: %d（快照声明 %d）\n\n", len(items), len(items))
	clusterRefs := map[competitionmatching.Cluster]int{}
	exactMajorRefs := map[string]int{}
	clusterEvents := map[competitionmatching.Cluster][]string{}
	for index := range candidates {
		for _, cluster := range candidates[index].ClusterScope.Clusters {
			clusterRefs[cluster]++
			clusterEvents[cluster] = append(clusterEvents[cluster], candidates[index].CompetitionID)
		}
		for _, major := range candidates[index].ClusterScope.ExactMajors {
			exactMajorRefs[major]++
		}
	}

	fmt.Println("=== 1. 专业簇引用分布（目录侧实际在用）===")
	type clusterCount struct {
		cluster competitionmatching.Cluster
		count   int
	}
	used := make([]clusterCount, 0, len(clusterRefs))
	for cluster, count := range clusterRefs {
		used = append(used, clusterCount{cluster, count})
	}
	sort.Slice(used, func(i, j int) bool {
		if used[i].count != used[j].count {
			return used[i].count > used[j].count
		}
		return used[i].cluster < used[j].cluster
	})
	for _, entry := range used {
		mark := ""
		if competitionmatching.IsBroadCluster(entry.cluster) {
			mark = "  [宽口径]"
		}
		fmt.Printf("  %-24s %4d 场%s\n", entry.cluster, entry.count, mark)
	}

	fmt.Println("\n=== 2. 词表里没有任何赛事引用的簇（可考虑收敛词表）===")
	unused := make([]string, 0)
	for _, cluster := range competitionmatching.ClusterOptions() {
		if clusterRefs[competitionmatching.Cluster(cluster)] == 0 {
			unused = append(unused, cluster)
		}
	}
	if len(unused) == 0 {
		fmt.Println("  无")
	} else {
		sort.Strings(unused)
		fmt.Printf("  %d 项：%s\n", len(unused), strings.Join(unused, "、"))
	}

	fmt.Println("\n=== 3. 没有任何标准专业映射到的簇（该方向的学生只能靠兜底命中）===")
	mapped := map[competitionmatching.Cluster]int{}
	for _, clusters := range competitionmatching.MajorClusterMap() {
		for _, cluster := range clusters {
			mapped[cluster]++
		}
	}
	orphan := make([]competitionmatching.Cluster, 0)
	for _, cluster := range competitionmatching.ClusterOptions() {
		if mapped[competitionmatching.Cluster(cluster)] == 0 {
			orphan = append(orphan, competitionmatching.Cluster(cluster))
		}
	}
	if len(orphan) == 0 {
		fmt.Println("  无")
	} else {
		for _, cluster := range orphan {
			fmt.Printf("  %-24s 被 %d 场赛事引用\n", cluster, clusterRefs[cluster])
		}
		fmt.Println("  → 处理方式：在 academic_majors 中补上对应专业，或在目录侧把该簇收敛到相邻方向。")
	}

	fmt.Println("\n=== 4. 宽口径「-相关」类标签分布（噪声来源，对应计划 D3）===")
	broad := make([]competitionmatching.Cluster, 0)
	for cluster := range clusterRefs {
		if competitionmatching.IsBroadCluster(cluster) {
			broad = append(broad, cluster)
		}
	}
	sort.Slice(broad, func(i, j int) bool { return clusterRefs[broad[i]] > clusterRefs[broad[j]] })
	for _, cluster := range broad {
		fmt.Printf("  %-24s %4d 场\n", cluster, clusterRefs[cluster])
	}
	if len(broad) == 0 {
		fmt.Println("  无")
	}

	fmt.Println("\n=== 5. 目录侧未识别标签（必须逐项登记，对应边界契约 B14）===")
	if len(unknownLabels) == 0 {
		fmt.Println("  无")
	} else {
		keys := make([]string, 0, len(unknownLabels))
		for key := range unknownLabels {
			keys = append(keys, key)
		}
		sort.Strings(keys)
		for _, key := range keys {
			fmt.Printf("  %-24s 出现 %d 次\n", key, unknownLabels[key])
		}
	}

	fmt.Println("\n=== 6. 疑似标签错配（标题学科词与 eligible_majors 无交集，须人工复核）===")
	suspects := 0
	for index := range items {
		item := items[index]
		candidate := candidates[index]
		if len(candidate.ClusterScope.Clusters) == 0 {
			continue
		}
		offer := map[competitionmatching.Cluster]struct{}{}
		for _, cluster := range candidate.ClusterScope.Clusters {
			offer[cluster] = struct{}{}
		}
		for _, rule := range expectedClustersByKeyword {
			if !strings.Contains(item.Title, rule.keyword) {
				continue
			}
			// 复合词误命中：标题里的学科词只是另一个词的组成部分，跳过该规则。
			excluded := false
			for _, value := range rule.excluded {
				if strings.Contains(item.Title, value) {
					excluded = true
					break
				}
			}
			if excluded {
				continue
			}
			matched := false
			for _, expected := range rule.expected {
				if _, ok := offer[expected]; ok {
					matched = true
					break
				}
			}
			if matched {
				break
			}
			suspects++
			labels := make([]string, 0, len(candidate.ClusterScope.Clusters))
			for _, cluster := range candidate.ClusterScope.Clusters {
				labels = append(labels, string(cluster))
			}
			fmt.Printf("  %-12s %s\n", item.CompetitionID, truncate(item.Title, 40))
			fmt.Printf("  %-12s   标题含「%s」，但只面向 %s\n", "", rule.keyword, strings.Join(labels, "、"))
			break
		}
	}
	if suspects == 0 {
		fmt.Println("  无")
	} else {
		fmt.Printf("  共 %d 条待复核。修复必须走 admin catalog 的 validate → import → diff → activate，禁止直接改库。\n", suspects)
	}

	fmt.Println("\n=== 7. 赛事直接标注标准专业全名的情况（legacy 兼容路径）===")
	if len(exactMajorRefs) == 0 {
		fmt.Println("  无（目录已全部使用簇口径）")
	} else {
		keys := make([]string, 0, len(exactMajorRefs))
		for key := range exactMajorRefs {
			keys = append(keys, key)
		}
		sort.Strings(keys)
		for _, key := range keys {
			fmt.Printf("  %-24s %4d 场\n", key, exactMajorRefs[key])
		}
	}

	printGradeGateAudit(candidates, "2023")
}

// printGradeGateAudit 追问「年级门淘汰掉的到底是哪些赛事」。
//
// 年级是唯一保留的淘汰原因，因此必须能逐项说清：这 47 条是真实不适配，
// 还是口径不一致导致的误伤。判定复用 competitionmatching.ResolveEntryScope，
// 因此这里报出的「真实不适配」与线上门禁的结论必然一致。
func printGradeGateAudit(candidates []competitionmatching.Candidate, entryYear string) {
	fmt.Println("\n=== 8. 年级门淘汰明细（唯一保留的淘汰原因）===")
	undergraduate := competitionmatching.ResolveUser(competitionmatching.UserProfile{
		Major: "计算机科学与技术", College: "信息科学与工程学院",
		EntryYear: entryYear, Grade: "本科" + entryYear + "级",
	})
	postgraduate := competitionmatching.ResolveUser(competitionmatching.UserProfile{
		Major: "计算机科学与技术", College: "信息科学与工程学院",
		EntryYear: entryYear, Grade: "研究生" + entryYear + "级",
	})

	for _, probe := range []struct {
		label string
		user  competitionmatching.ResolvedUser
	}{{"本科生", undergraduate}, {"研究生", postgraduate}} {
		grouped := map[string]int{}
		dropped := 0
		for index := range candidates {
			scope := competitionmatching.ResolveEntryScope(candidates[index].EntryYears)
			if scope.Empty || scope.Allows(probe.user) {
				continue
			}
			dropped++
			grouped[strings.Join(candidates[index].EntryYears, " / ")]++
		}
		fmt.Printf("  %s画像被淘汰 %d 条：\n", probe.label, dropped)
		keys := make([]string, 0, len(grouped))
		for key := range grouped {
			keys = append(keys, key)
		}
		sort.Slice(keys, func(i, j int) bool {
			if grouped[keys[i]] != grouped[keys[j]] {
				return grouped[keys[i]] > grouped[keys[j]]
			}
			return keys[i] < keys[j]
		})
		for _, key := range keys {
			fmt.Printf("    %-46s %3d 条\n", truncate(key, 44), grouped[key])
		}
	}

	fmt.Println("  说明：该字段线上存的是学历层次（研究生 / 已获研究生入学资格的本科生 / 本科生），")
	fmt.Println("        不是四位年份；门禁按层次语义比对，四位年份仍按年份比对，")
	fmt.Println("        无法识别的取值一律放行（不得因为「不认识」而淘汰）。")
	fmt.Println("  另需登记：无法识别的年级取值清单——")
	unknown := map[string]int{}
	for index := range candidates {
		for _, value := range competitionmatching.ResolveEntryScope(candidates[index].EntryYears).Unknown {
			unknown[value]++
		}
	}
	if len(unknown) == 0 {
		fmt.Println("    无")
	} else {
		keys := make([]string, 0, len(unknown))
		for key := range unknown {
			keys = append(keys, key)
		}
		sort.Strings(keys)
		for _, key := range keys {
			fmt.Printf("    %-46s %3d 条\n", key, unknown[key])
		}
	}
}

func rankIDs(
	candidates []competitionmatching.Candidate,
	user competitionmatching.ResolvedUser,
	now time.Time,
) []uint {
	ranked := make([]competitionmatching.Ranked, 0, len(candidates))
	for _, candidate := range candidates {
		result := competitionmatching.Score(competitionmatching.ScoreInput{
			Candidate: candidate, User: user, Now: now,
		})
		if result.GroupKey == "" {
			continue
		}
		ranked = append(ranked, competitionmatching.Ranked{
			ID: candidate.ID, CompetitionID: candidate.CompetitionID,
			CatalogOrder: candidate.CatalogOrder, Rating: candidate.Rating,
			Importance: candidate.ImportanceScore, Result: result,
		})
	}
	ordered := competitionmatching.Rank(ranked, competitionmatching.RankOptions{PageSize: 20})
	ids := make([]uint, 0, len(ordered))
	for _, item := range ordered {
		ids = append(ids, item.ID)
	}
	return ids
}
