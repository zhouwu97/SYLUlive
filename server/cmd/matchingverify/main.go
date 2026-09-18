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
