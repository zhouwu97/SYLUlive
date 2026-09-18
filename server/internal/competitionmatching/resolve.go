package competitionmatching

import (
	"sort"
	"strings"
)

// UserProfile 是打分所需的用户侧最小画像。
// 只包含结构化字段，不包含任何证明材料或经历原文。
type UserProfile struct {
	Major     string
	College   string
	EntryYear string
	// Grade 是教务口径的年级原文（如「本科2023级」），用于判断学历层次。
	Grade string
	// ClusterOverride 来自用户手动纠正（user_competition_preferences.major_cluster_override）。
	// 一旦存在就完全取代字典推断——用户显式意图优先于系统推断。
	ClusterOverride []string
}

// ResolvedUser 是用户侧解析结果。
type ResolvedUser struct {
	Clusters  []Cluster
	College   string
	Major     string
	EntryYear string
	// Postgraduate 表示用户是研究生（含硕士、博士）。学籍是本科还是研究生
	// 决定能否命中「研究生」这类参赛范围，光有入学年份判断不出来。
	Postgraduate bool
	// Unmapped 为 true 表示专业名无法映射到任何簇。
	// 调用方必须把这种情况作为可见缺口上报，而不是当成普通的「未命中」。
	Unmapped bool
	// FromOverride 表示簇来自用户手动纠正而非字典推断。
	FromOverride bool
}

// ResolveUser 解析用户侧专业簇。
func ResolveUser(profile UserProfile) ResolvedUser {
	result := ResolvedUser{
		College:      strings.TrimSpace(profile.College),
		Major:        strings.TrimSpace(profile.Major),
		EntryYear:    strings.TrimSpace(profile.EntryYear),
		Postgraduate: isPostgraduateGrade(profile.Grade),
	}
	if values := normalizeClusterValues(profile.ClusterOverride); len(values) > 0 {
		result.Clusters = values
		result.FromOverride = true
		return result
	}
	clusters, mapped := LookupMajorClusters(profile.Major)
	if !mapped {
		result.Unmapped = true
		return result
	}
	result.Clusters = clusters
	return result
}

// postgraduateGradeKeywords 用于判断学历层次。教务年级字段是自由文本，
// 因此这里只做关键词判定，判不出来时按本科处理（在校生的默认情形）。
var postgraduateGradeKeywords = []string{"研究生", "硕士", "博士", "mba", "mpa", "mem"}

func isPostgraduateGrade(grade string) bool {
	value := strings.ToLower(strings.TrimSpace(grade))
	if value == "" {
		return false
	}
	for _, keyword := range postgraduateGradeKeywords {
		if strings.Contains(value, keyword) {
			return true
		}
	}
	return false
}

// EventMajorScope 是赛事侧解析结果。
type EventMajorScope struct {
	Clusters []Cluster
	// ExactMajors 保留赛事原始标注中的标准专业全名，用于「精确命中」的额外加分。
	ExactMajors []string
	// UnknownLabels 是既不是合法簇、也无法识别为专业名的标签。
	// 这些标签必须能在覆盖率报告里被看到（对应边界契约 B14）。
	UnknownLabels []string
}

// ResolveEventMajors 解析赛事侧的 eligible_majors。
//
// 双向可解析是刻意设计：目录新包使用簇标签，而 legacy 数据可能存放标准专业名，
// 两种口径都要能正确参与匹配，避免在数据侧做一次性语法迁移。
func ResolveEventMajors(values []string) EventMajorScope {
	result := EventMajorScope{
		Clusters:      []Cluster{},
		ExactMajors:   []string{},
		UnknownLabels: []string{},
	}
	seenCluster := make(map[Cluster]struct{})
	seenUnknown := make(map[string]struct{})
	for _, raw := range values {
		value := strings.TrimSpace(raw)
		if value == "" {
			continue
		}
		if IsStandardCluster(value) {
			cluster := Cluster(value)
			if _, exists := seenCluster[cluster]; !exists {
				seenCluster[cluster] = struct{}{}
				result.Clusters = append(result.Clusters, cluster)
			}
			continue
		}
		// 不是簇标签时，尝试按标准专业名解析：这是 legacy 兼容路径。
		if clusters, mapped := LookupMajorClusters(value); mapped {
			result.ExactMajors = append(result.ExactMajors, value)
			for _, cluster := range clusters {
				if _, exists := seenCluster[cluster]; exists {
					continue
				}
				seenCluster[cluster] = struct{}{}
				result.Clusters = append(result.Clusters, cluster)
			}
			continue
		}
		if _, exists := seenUnknown[value]; !exists {
			seenUnknown[value] = struct{}{}
			result.UnknownLabels = append(result.UnknownLabels, value)
		}
	}
	return result
}

// normalizeClusterValues 把自由文本簇值归一为合法簇，丢弃无法识别的值。
func normalizeClusterValues(values []string) []Cluster {
	result := make([]Cluster, 0, len(values))
	seen := make(map[Cluster]struct{}, len(values))
	for _, raw := range values {
		value := Cluster(strings.TrimSpace(raw))
		if !IsStandardCluster(string(value)) {
			continue
		}
		if _, exists := seen[value]; exists {
			continue
		}
		seen[value] = struct{}{}
		result = append(result, value)
	}
	sort.Slice(result, func(i, j int) bool { return result[i] < result[j] })
	return result
}

// IntersectClusters 返回用户簇与赛事簇的交集，结果按字典序稳定排序。
func IntersectClusters(user []Cluster, event []Cluster) []Cluster {
	if len(user) == 0 || len(event) == 0 {
		return nil
	}
	eventSet := make(map[Cluster]struct{}, len(event))
	for _, value := range event {
		eventSet[value] = struct{}{}
	}
	result := make([]Cluster, 0, len(user))
	for _, value := range user {
		if _, ok := eventSet[value]; ok {
			result = append(result, value)
		}
	}
	sort.Slice(result, func(i, j int) bool { return result[i] < result[j] })
	return result
}

// FilterBroadClusters 剔除宽口径标签，只保留能说明真实相关性的簇。
// 宽标签会在 §score 里以较低权重单独计分，不参与「直接相关」的判定。
func FilterBroadClusters(values []Cluster) []Cluster {
	result := make([]Cluster, 0, len(values))
	for _, value := range values {
		if IsBroadCluster(value) {
			continue
		}
		result = append(result, value)
	}
	return result
}

// ContainsFold 做大小写与空白无关的等值比较，用于学院等自由文本字段。
// 刻意不做子串匹配：学院名是自由文本，子串匹配会把「信息学院」误配到「信息科学与工程学院」之外的值。
func ContainsFold(values []string, expected string) bool {
	expected = NormalizeMajor(expected)
	if expected == "" {
		return false
	}
	for _, value := range values {
		if NormalizeMajor(value) == expected {
			return true
		}
	}
	return false
}

// EntryScope 是赛事 side `eligible_entry_years` 的解析结果。
//
// 字段名叫「entry_years」，但线上实际取值是**学历层次**而不是年份：
// 310 条里 47 条有值，全部是「研究生 / 已获研究生入学资格的本科生 / 本科生」，
// 没有一条是四位年份。旧实现拿它和用户的入学年份做字符串全等比较，
// 于是「本科生」这两条赛事对任何本科生都被判为不符——**真正合规的用户被淘汰**。
// 解析成两类口径后，门禁才按语义生效：层次归层次，年份归年份。
type EntryScope struct {
	// Postgraduate 表示赛事面向研究生（含已获研究生入学资格的本科生）。
	Postgraduate bool
	// Undergraduate 表示赛事面向本科生。
	Undergraduate bool
	// Years 是四位入学年份，字段将来若真的填年份，按年份比对。
	Years map[string]struct{}
	// Unknown 是无法识别的取值。必须可见（与 B14 同理），且不得据此淘汰。
	Unknown []string
	// Empty 表示赛事没有声明年级范围（310 条里 263 条如此），一律放行。
	Empty bool
}

// ResolveEntryScope 解析赛事声明的参赛年级范围。
func ResolveEntryScope(values []string) EntryScope {
	scope := EntryScope{Years: map[string]struct{}{}}
	for _, raw := range values {
		value := strings.TrimSpace(raw)
		if value == "" {
			continue
		}
		if isFourDigitYear(value) {
			scope.Years[value] = struct{}{}
			continue
		}
		normalized := NormalizeMajor(value)
		switch {
		case strings.Contains(normalized, "研究生") || strings.Contains(normalized, "硕士") ||
			strings.Contains(normalized, "博士"):
			scope.Postgraduate = true
		case strings.Contains(normalized, "本科") || strings.Contains(normalized, "专科"):
			scope.Undergraduate = true
		default:
			scope.Unknown = append(scope.Unknown, value)
		}
	}
	scope.Empty = !scope.Postgraduate && !scope.Undergraduate && len(scope.Years) == 0
	return scope
}

// Allows 判断用户是否落在赛事声明的年级范围内。
//
// 保守原则与其它资格字段一致：**只有口径明确时才可以淘汰**。
// 若赛事只声明了无法识别的取值，一律放行——把不认识的值当成「不符」
// 正是「数据越全、越推荐不到」那类缺陷的成因。
func (s EntryScope) Allows(user ResolvedUser) bool {
	if s.Empty {
		return true
	}
	if len(s.Years) > 0 {
		if _, ok := s.Years[user.EntryYear]; ok {
			return true
		}
	}
	if s.Postgraduate && user.Postgraduate {
		return true
	}
	if s.Undergraduate && !user.Postgraduate {
		return true
	}
	if len(s.Years) == 0 && !s.Postgraduate && !s.Undergraduate {
		return true
	}
	return false
}

func isFourDigitYear(value string) bool {
	if len(value) != 4 {
		return false
	}
	for _, char := range value {
		if char < '0' || char > '9' {
			return false
		}
	}
	return true
}
