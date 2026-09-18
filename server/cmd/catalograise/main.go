// Command catalograise 生成「开放个性化排序」的目录包（ADR-002 阶段 2 的发布前置）。
//
// 为什么需要它：personalized_ranking_allowed 的权威来源是目录包 JSON，
// 直接改库会在下一次目录激活时被静默回滚。而手工编辑 JSON 又不可能正确——
// record_hash 是对整条记录取哈希、package_hash 再对所有记录摘要取哈希，
// 手改一个布尔值就会让全包校验失败。
//
// 本工具复用**服务端同一份**哈希实现（services.ComputeCompetitionRecordHash /
// ComputeCompetitionPackageHash），因此产出与导入时的校验必然一致；
// 绝不另写一份哈希算法——那正是「离线工具与线上漂移」的来源。
//
// 用法（默认只做 dry-run，不写文件）：
//
//	go run ./cmd/catalograise -input catalog.json -college 信息科学与工程学院
//	go run ./cmd/catalograise -input catalog.json -college 信息科学与工程学院 -apply -output pilot.json
//	go run ./cmd/catalograise -input catalog.json -all -apply -output full.json -dataset-version 2026.09.22-v8.3-activation
//
// 发布链路（缺一不可）：
//
//	导出 → 本工具生成新包 → validate_catalog_v2.py → 后台 import → diff 复核 → activate
package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"strings"

	"shenliyuan/internal/dto"
	"shenliyuan/internal/services"
)

type raiseResult struct {
	Document          dto.CompetitionCatalogDocument
	Changed           []string
	AlreadyOpen       int
	SkippedPoolClosed []string
	SkippedOutOfScope []string
}

func main() {
	inputPath := flag.String("input", "", "现有目录包 JSON 路径")
	outputPath := flag.String("output", "", "输出路径（-apply 时必填）")
	college := flag.String("college", "", "只翻转 eligible_colleges 含该学院的赛事（试点包）")
	all := flag.Bool("all", false, "翻转全部候选池内赛事（全量包）")
	apply := flag.Bool("apply", false, "实际写文件；不传则只做 dry-run")
	datasetVersion := flag.String("dataset-version", "", "覆盖 dataset_version（留空保持不变）")
	flag.Parse()

	if *inputPath == "" {
		exitf("必须指定 -input")
	}
	if !*all && strings.TrimSpace(*college) == "" {
		exitf("必须二选一：-college <学院名>（试点包）或 -all（全量包）")
	}
	if *all && strings.TrimSpace(*college) != "" {
		exitf("-all 与 -college 不能同时使用")
	}
	if *apply && *outputPath == "" {
		exitf("-apply 必须同时指定 -output")
	}

	raw, err := os.ReadFile(*inputPath)
	if err != nil {
		exitf("读取目录包失败: %v", err)
	}
	var document dto.CompetitionCatalogDocument
	if err := json.Unmarshal(raw, &document); err != nil {
		exitf("解析目录包失败: %v", err)
	}
	if len(document.Items) == 0 {
		exitf("目录包没有任何记录，拒绝处理")
	}

	result, err := raisePersonalizedRanking(document, raiseOptions{
		College:        strings.TrimSpace(*college),
		All:            *all,
		DatasetVersion: strings.TrimSpace(*datasetVersion),
	})
	if err != nil {
		exitf("生成新包失败: %v", err)
	}

	fmt.Printf("输入包: %s（dataset=%s，%d 条）\n", *inputPath, document.DatasetVersion, len(document.Items))
	fmt.Printf("翻转范围: %s\n", describeScope(*all, *college))
	fmt.Printf("本次翻转 %d 条，已开放 %d 条，候选池外跳过 %d 条，范围外跳过 %d 条\n",
		len(result.Changed), result.AlreadyOpen, len(result.SkippedPoolClosed), len(result.SkippedOutOfScope))
	if len(result.Changed) > 0 {
		fmt.Println("翻转明细（前 20 条）:")
		for index, id := range result.Changed {
			if index >= 20 {
				fmt.Printf("  … 其余 %d 条见输出文件\n", len(result.Changed)-20)
				break
			}
			fmt.Printf("  %s\n", id)
		}
	}
	fmt.Printf("新 package_hash: %s\n", result.Document.PackageHash)
	if result.Document.DatasetVersion == document.DatasetVersion {
		fmt.Println("提示: dataset_version 未变化。建议同时升级版本，便于回滚时区分两包。")
	}
	fmt.Println("注意: strong_recommendation_eligible 全线保持 false，本工具不会触碰它。")

	if !*apply {
		fmt.Println("\n当前为 dry-run，未写入任何文件。确认无误后加 -apply 重新执行。")
		return
	}
	encoded, err := json.MarshalIndent(result.Document, "", "  ")
	if err != nil {
		exitf("编码输出失败: %v", err)
	}
	encoded = append(encoded, '\n')
	if err := os.WriteFile(*outputPath, encoded, 0o644); err != nil {
		exitf("写入输出失败: %v", err)
	}
	fmt.Printf("\n已写入 %s\n", *outputPath)
	fmt.Println("后续: validate_catalog_v2.py → 后台 import → diff 复核 → activate（禁止直接改库）")
}

type raiseOptions struct {
	College        string
	All            bool
	DatasetVersion string
}

func describeScope(all bool, college string) string {
	if all {
		return "全部候选池内赛事（全量包）"
	}
	return fmt.Sprintf("eligible_colleges 含「%s」的赛事（试点包）", college)
}

// raisePersonalizedRanking 生成开放个性化排序的新包。
//
// 三条不可退让的约束（对应 ADR-002 与目录校验器）：
//  1. 只翻转 candidate_pool_allowed=true 的记录：未进候选池不得开放个性化排序；
//  2. 绝不触碰 strong_recommendation_eligible：排序与强推荐必须保持解耦；
//  3. 翻转后必须重算 record_hash 与 package_hash，否则导入时校验必然失败。
func raisePersonalizedRanking(
	document dto.CompetitionCatalogDocument,
	options raiseOptions,
) (raiseResult, error) {
	result := raiseResult{Document: document}
	// 先拷贝一份记录切片再改：Go 的切片共享底层数组，
	// 直接改 result.Document.Items 会连带改掉调用方传入的 document，
	// 让「原包 vs 新包」无法比较，也让 dry-run 之后的任何复用都拿到已被改过的数据。
	result.Document.Items = append([]dto.CompetitionCatalogRecord(nil), document.Items...)
	if strings.TrimSpace(options.DatasetVersion) != "" {
		result.Document.DatasetVersion = strings.TrimSpace(options.DatasetVersion)
	}
	recordHashes := make(map[string]string, len(document.Items))
	for index := range result.Document.Items {
		record := &result.Document.Items[index]
		id := strings.TrimSpace(record.CompetitionID)
		if id == "" {
			return result, fmt.Errorf("第 %d 条记录缺少 competition_id", index+1)
		}
		if !record.CandidatePoolAllowed {
			// 候选池外：既不能翻转，也不能已经为 true（否则输入包本身违规）。
			if record.PersonalizedRankingAllowed {
				return result, fmt.Errorf("赛事 %s 未进候选池却已开放个性化排序，拒绝处理", id)
			}
			record.PersonalizedRankingAllowed = false
			result.SkippedPoolClosed = append(result.SkippedPoolClosed, id)
		} else if record.PersonalizedRankingAllowed {
			result.AlreadyOpen++
		} else if options.All || containsFold(record.EligibleColleges, options.College) {
			record.PersonalizedRankingAllowed = true
			result.Changed = append(result.Changed, id)
		} else {
			result.SkippedOutOfScope = append(result.SkippedOutOfScope, id)
		}
		if record.StrongRecommendationEligible {
			return result, fmt.Errorf("赛事 %s 的强推荐字段为 true，本工具不处理强推荐，拒绝继续", id)
		}
		hash, err := services.ComputeCompetitionRecordHash(*record)
		if err != nil {
			return result, fmt.Errorf("重算 %s 的记录摘要失败: %w", id, err)
		}
		record.RecordHash = hash
		recordHashes[id] = hash
	}
	packageHash, err := services.ComputeCompetitionPackageHash(result.Document, recordHashes)
	if err != nil {
		return result, fmt.Errorf("重算包摘要失败: %w", err)
	}
	result.Document.PackageHash = packageHash
	return result, nil
}

func containsFold(values []string, expected string) bool {
	if strings.TrimSpace(expected) == "" {
		return false
	}
	for _, value := range values {
		if strings.TrimSpace(value) == expected {
			return true
		}
	}
	return false
}

func exitf(format string, args ...interface{}) {
	fmt.Fprintf(os.Stderr, format+"\n", args...)
	os.Exit(2)
}
