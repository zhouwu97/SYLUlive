package competitionmatching

import (
	"sort"
	"strings"
	"time"
)

// AlgorithmVersion 标识本次打分排序的算法版本。
// 埋点、trace 与离线评估都按此切分，便于新旧算法对比与回滚。
const AlgorithmVersion = "major-match-v1"

// 分组键。与既有目录/前端约定的三组语义保持一致，
// 但分组依据改为「专业簇是否命中」而不是「专业名是否全等」。
const (
	GroupMajorMatch   = "major_match"
	GroupCollegeMatch = "college_match"
	GroupGeneralMatch = "general_match"
)

// 匹配依据。向学生暴露的离散值，不暴露数值。
const (
	BasisMajorCluster = "major_cluster"
	BasisCollege      = "college"
	BasisTagBridge    = "tag_bridge"
	BasisGeneral      = "general"
)

// 匹配档位。离散标签，避免伪精确总分（dto/competition_candidate.go:39）。
const (
	TierStrong   = "strong"
	TierSuitable = "suitable"
	TierExplore  = "explore"
	TierNone     = "none"
)

// 离散维度取值，与客户端 _dimensionLabel 的取词保持一致。
const (
	DimMatched      = "matched"
	DimUnmatched    = "unmatched"
	DimUnrestricted = "unrestricted"
	DimUnknown      = "unknown"
)

// 分值上限。M 远大于 V 是刻意设计：专业相关度是用户提出的一级需求，
// 而 competition_rating 是人工评级，必须与匹配度严格分野。
const (
	maxMajorScore      = 40
	maxExactMajorBonus = 6
	maxPreferenceScore = 22
	maxGoalScore       = 12
	maxTimeScore       = 10
	maxValueScore      = 10
	maxPenalty         = 15
)

// Candidate 是打分所需的赛事侧最小输入。
type Candidate struct {
	ID            uint
	CompetitionID string
	CatalogOrder  int

	ClusterScope EventMajorScope
	Colleges     []string
	EntryYears   []string
	Tags         []string
	CategorySlug string
	RiskTags     []string

	Rating                  string
	ImportanceScore         int
	SchoolRecognitionStatus string

	TimeStatus      string
	RegistrationEnd *time.Time
	EventStart      *time.Time

	EvidenceSubgrade  string
	ParticipationType string
	TeamSizeMin       int
	TeamSizeMax       int

	PersonalizedRankingAllowed bool
}

// Preference 是用户侧偏好与行为输入。
type Preference struct {
	Configured             bool
	Goals                  []string
	DirectionTags          []string
	SkillTags              []string
	PreferredRoles         []string
	WeeklyHours            int
	AcceptLongTermTraining bool
	CareerDirection        string

	// 行为信号。P1 只用已存在的「加入计划」；曝光次数在埋点落地后启用。
	JoinedPlan         bool
	ImpressionSessions int
	HasAward           bool
}

// Breakdown 是分项明细。仅用于内部排序、trace 与治理断言，
// 不直接作为数值暴露给学生。
type Breakdown struct {
	Major      int `json:"major"`
	Preference int `json:"preference"`
	Goal       int `json:"goal"`
	Time       int `json:"time"`
	Value      int `json:"value"`
	Penalty    int `json:"penalty"`
}

// Dimensions 是离散匹配维度，直接对应 dto.MatchDimensionsDTO。
type Dimensions struct {
	Major     string
	College   string
	Grade     string
	Goal      string
	Direction string
	Skill     string
	Role      string
	Time      string
	Training  string
}

// Result 是单条赛事的打分结果。
type Result struct {
	Score           int
	Tier            string
	Basis           string
	GroupKey        string
	MatchedClusters []Cluster
	MatchedLabels   []string
	Breakdown       Breakdown
	Dimensions      Dimensions
	Reasons         []string
	// Rankable 表示该赛事是否被授权参与个性化排序。
	// 未授权赛事仍可出现于结果集，但不得参与打分排序（治理约束）。
	Rankable bool
}

// ScoreInput 聚合一次打分的全部输入。
type ScoreInput struct {
	Candidate  Candidate
	User       ResolvedUser
	Preference Preference
	Now        time.Time
}

// Score 计算单条赛事的匹配结果。纯函数：同一输入必然得到同一输出。
//
// 关键设计：匹配与排序授权是两件事，必须解耦。
//   - 匹配（分组 / 依据 / 离散维度 / 档位）是事实描述，**永远计算**，
//     与赛事是否被授权个性化排序无关。否则在目录尚未普遍授权时
//     （现状 310/310 均为 false）匹配会整体失效，等于把功能关掉。
//   - 授权只约束一件事：该赛事的分值是否参与排序（Rankable）。
//     未授权赛事由 rank.go 回退到目录序位置，其顺序不受画像影响。
func Score(input ScoreInput) Result {
	candidate := input.Candidate
	user := input.User
	preference := input.Preference

	result := Result{
		Rankable: candidate.PersonalizedRankingAllowed,
		Dimensions: Dimensions{
			Major: DimUnrestricted, College: DimUnrestricted, Grade: DimUnrestricted,
			Goal: DimUnknown, Direction: DimUnknown, Skill: DimUnknown,
			Role: DimUnknown, Time: DimUnknown, Training: DimUnknown,
		},
	}

	// 年级资格：唯一保留的硬门（唯一有明确排他语义的字段）。
	if len(candidate.EntryYears) > 0 {
		if !ContainsFold(candidate.EntryYears, user.EntryYear) {
			result.Tier = TierNone
			result.GroupKey = ""
			return result
		}
		result.Dimensions.Grade = DimMatched
	}

	// —— M 专业匹配（互斥取最高，不叠加）——
	strong := FilterBroadClusters(IntersectClusters(user.Clusters, candidate.ClusterScope.Clusters))
	broad := intersectBroadClusters(user.Clusters, candidate.ClusterScope.Clusters)
	collegeHit := ContainsFold(candidate.Colleges, user.College)
	bridged := bridgedClusters(user.Clusters, candidate)

	switch {
	case len(strong) > 0:
		result.Basis = BasisMajorCluster
		result.GroupKey = GroupMajorMatch
		result.Breakdown.Major = maxMajorScore
		result.MatchedClusters = strong
		result.Dimensions.Major = DimMatched
		result.Reasons = append(result.Reasons, "你的专业属于"+joinClusters(strong)+"，该赛事面向同一方向开放")
	case collegeHit:
		result.Basis = BasisCollege
		result.GroupKey = GroupCollegeMatch
		result.Breakdown.Major = 26
		result.Dimensions.College = DimMatched
		result.Reasons = append(result.Reasons, "面向你所在的"+user.College+"开放")
	case len(broad) > 0:
		result.Basis = BasisTagBridge
		result.GroupKey = GroupGeneralMatch
		result.Breakdown.Major = 22
		result.MatchedClusters = broad
		result.Dimensions.Major = DimMatched
		result.Reasons = append(result.Reasons, "赛事方向与你所学存在关联（口径较宽，建议核对具体要求）")
	case len(bridged) > 0:
		result.Basis = BasisTagBridge
		result.GroupKey = GroupGeneralMatch
		result.Breakdown.Major = 16
		result.MatchedClusters = bridged
		result.Dimensions.Major = DimMatched
		result.Reasons = append(result.Reasons, "赛事方向与你所学方向相近")
	default:
		result.Basis = BasisGeneral
		result.GroupKey = GroupGeneralMatch
		result.Breakdown.Major = 8
		result.Dimensions.Major = DimUnmatched
		result.Reasons = append(result.Reasons, "符合当前参赛资格，可作为通用候选")
	}
	// 赛事直接标注了用户的标准专业全名时给额外加分（最强的精确信号）。
	if exactMajorHit(user.Major, candidate) {
		result.Breakdown.Major += maxExactMajorBonus
	}

	// —— P 偏好 ——
	result.Breakdown.Preference, result.Dimensions.Direction, result.Dimensions.Skill, result.Dimensions.Role =
		scorePreference(user, candidate, preference, &result.Reasons)

	// —— G 目标 ——
	result.Breakdown.Goal, result.Dimensions.Goal =
		scoreGoal(candidate, preference, &result.Reasons)

	// —— T 时间投入 ——
	result.Breakdown.Time, result.Dimensions.Time, result.Dimensions.Training =
		scoreTime(candidate, preference, &result.Reasons)

	// —— V 赛事价值（与匹配度严格分野，上限压到 10 分）——
	result.Breakdown.Value = scoreValue(candidate)

	// —— 惩罚项：只降权不淘汰 ——
	result.Breakdown.Penalty = scorePenalty(candidate, preference, input.Now, &result.Reasons)

	total := result.Breakdown.Major + result.Breakdown.Preference + result.Breakdown.Goal +
		result.Breakdown.Time + result.Breakdown.Value - result.Breakdown.Penalty
	result.Score = clamp(total, 0, 100)
	result.Tier = tierFor(result.Score)
	return result
}

// intersectBroadClusters 返回只由宽口径标签构成的交集。
func intersectBroadClusters(user []Cluster, event []Cluster) []Cluster {
	return filterClusters(IntersectClusters(user, event), true)
}

func filterClusters(values []Cluster, broad bool) []Cluster {
	result := make([]Cluster, 0, len(values))
	for _, value := range values {
		if IsBroadCluster(value) == broad {
			result = append(result, value)
		}
	}
	return result
}

func joinClusters(values []Cluster) string {
	parts := make([]string, 0, len(values))
	for _, value := range values {
		parts = append(parts, string(value))
	}
	return strings.Join(parts, "、")
}

func exactMajorHit(major string, candidate Candidate) bool {
	key := NormalizeMajor(major)
	if key == "" {
		return false
	}
	for _, value := range candidate.ClusterScope.ExactMajors {
		if NormalizeMajor(value) == key {
			return true
		}
	}
	return false
}

// scorePreference 计算偏好分量，并回填方向/技能/角色三个离散维度。
func scorePreference(
	user ResolvedUser,
	candidate Candidate,
	preference Preference,
	reasons *[]string,
) (points int, direction, skill, role string) {
	direction, skill, role = DimUnknown, DimUnknown, DimUnknown
	if !preference.Configured {
		return 0, direction, skill, role
	}
	offer := offerClusterSet(candidate)

	// 方向：用户选的方向标签经桥接表落到簇，再看是否被赛事覆盖。
	if len(preference.DirectionTags) > 0 {
		hit := 0
		for _, tag := range preference.DirectionTags {
			for _, cluster := range ClusterBridgeForDirection(tag) {
				if _, ok := offer[cluster]; ok {
					hit++
					break
				}
			}
		}
		if hit > 0 {
			points += minInt(hit*8, 12)
			direction = DimMatched
			*reasons = appendUnique(*reasons, "与你关注的"+strings.TrimSpace(preference.DirectionTags[0])+"方向一致")
		} else {
			direction = DimUnmatched
		}
	} else {
		direction = DimUnknown
	}

	// 技能：赛事标签命中用户技能词。
	if len(preference.SkillTags) > 0 {
		hit := countTagHits(preference.SkillTags, candidate.Tags)
		if hit > 0 {
			points += minInt(hit*4, 8)
			skill = DimMatched
		} else {
			skill = DimUnmatched
		}
	}

	// 角色：沿用 competitionRoleKeywords 的闭集关键词，不做自由文本相似度。
	if len(preference.PreferredRoles) > 0 {
		text := searchableText(candidate)
		hit := 0
		for _, role := range preference.PreferredRoles {
			if roleKeywordHit(role, text) {
				hit++
			}
		}
		if hit > 0 {
			points += minInt(hit*5, 10)
			role = DimMatched
		} else {
			role = DimUnmatched
		}
	}

	// 职业方向：只做归一化后的等值比较，不使用子串包含（旧实现的噪声来源）。
	if career := NormalizeMajor(preference.CareerDirection); career != "" {
		for _, tag := range candidate.Tags {
			if NormalizeMajor(tag) == career {
				points += 4
				*reasons = appendUnique(*reasons, "与你填写的职业方向相关")
				break
			}
		}
	}
	return minInt(points, maxPreferenceScore), direction, skill, role
}

// scoreGoal 计算目标分量。分支沿用 legacy 实现已验证的语义。
func scoreGoal(candidate Candidate, preference Preference, reasons *[]string) (int, string) {
	if !preference.Configured || len(preference.Goals) == 0 {
		return 0, DimUnknown
	}
	points := 0
	for _, goal := range preference.Goals {
		switch strings.TrimSpace(goal) {
		case "resume":
			if ratingRank(candidate.Rating) >= ratingRank("B+") || candidate.ImportanceScore >= 70 {
				points += 8
				*reasons = appendUnique(*reasons, "赛事价值符合简历提升目标")
			}
		case "ability":
			points += 8
			*reasons = appendUnique(*reasons, "与你的能力成长目标一致")
		case "exploration":
			points += 5
			*reasons = appendUnique(*reasons, "适合探索新的竞赛方向")
		case "postgraduate":
			if candidate.SchoolRecognitionStatus == "recognized" || ratingRank(candidate.Rating) >= ratingRank("A") {
				points += 10
				*reasons = appendUnique(*reasons, "学校认定或赛事价值符合保研准备目标")
			}
		case "graduation_gap":
			// 毕业预警数据源尚未接入，该目标只保存，不参与加分（既有约定）。
		}
	}
	if points == 0 {
		return 0, DimUnmatched
	}
	return minInt(points, maxGoalScore), DimMatched
}

// scoreTime 计算时间投入分量。
func scoreTime(candidate Candidate, preference Preference, reasons *[]string) (int, string, string) {
	if !preference.Configured {
		return 0, DimUnknown, DimUnknown
	}
	points := 0
	timeDim := DimUnknown
	trainingDim := DimUnknown
	if preference.WeeklyHours > 0 {
		required := EstimatedWeeklyHours(candidate)
		if preference.WeeklyHours >= required {
			points += 8
			timeDim = DimMatched
			*reasons = appendUnique(*reasons, "适合你的每周投入区间")
		} else {
			timeDim = DimUnmatched
		}
	}
	if longTerm, known := IsLongTerm(candidate); known {
		if longTerm && preference.AcceptLongTermTraining {
			points += 4
			trainingDim = DimMatched
			*reasons = appendUnique(*reasons, "接受该赛事的长期准备周期")
		} else if !longTerm && !preference.AcceptLongTermTraining {
			points += 4
			trainingDim = DimMatched
			*reasons = appendUnique(*reasons, "准备周期符合短期项目偏好")
		} else {
			trainingDim = DimUnmatched
		}
	}
	return minInt(points, maxTimeScore), timeDim, trainingDim
}

// scoreValue 计算赛事价值分量。上限受 maxValueScore 严格控制，
// 确保人工评级无法压过专业匹配。
func scoreValue(candidate Candidate) int {
	points := 0
	switch strings.TrimSpace(candidate.Rating) {
	case "S", "A":
		points += 4
	case "B+", "B":
		points += 2
	case "B-", "C":
		points += 1
	}
	if candidate.ImportanceScore >= 80 {
		points += 2
	} else if candidate.ImportanceScore >= 50 {
		points += 1
	}
	return minInt(points, maxValueScore)
}

// scorePenalty 计算惩罚项。只降权，不淘汰——资格类字段的硬淘汰是本次修复的核心缺陷。
func scorePenalty(candidate Candidate, preference Preference, now time.Time, reasons *[]string) int {
	penalty := 0
	if candidate.TimeStatus == "pending" || (candidate.RegistrationEnd == nil && candidate.EventStart == nil) {
		penalty += 4
	}
	if candidate.RegistrationEnd != nil && candidate.RegistrationEnd.Before(now) {
		penalty += 8
		*reasons = appendUnique(*reasons, "当届报名已截止，可关注下一届")
	}
	if preference.WeeklyHours > 0 && preference.WeeklyHours <= 3 {
		for _, tag := range candidate.RiskTags {
			if tag == "high_weekly_hours" || tag == "high_time_cost" || tag == "long_term_training" {
				penalty += 6
				break
			}
		}
	}
	if strings.EqualFold(strings.TrimSpace(candidate.EvidenceSubgrade), "B2") {
		penalty += 3
	}
	if preference.JoinedPlan {
		penalty += 10
		*reasons = appendUnique(*reasons, "你已将该赛事加入计划")
	}
	if preference.HasAward {
		penalty += 10
	}
	return minInt(penalty, maxPenalty)
}

func tierFor(score int) string {
	switch {
	case score >= 72:
		return TierStrong
	case score >= 55:
		return TierSuitable
	case score >= 40:
		return TierExplore
	default:
		return TierNone
	}
}

// EstimatedWeeklyHours 估算赛事每周投入，沿用 legacy 实现的判定语义。
func EstimatedWeeklyHours(candidate Candidate) int {
	if longTerm, known := IsLongTerm(candidate); known && longTerm {
		return 14
	}
	text := searchableText(candidate)
	if strings.Contains(text, "训练") || strings.Contains(text, "联赛") || strings.Contains(text, "赛季") {
		return 14
	}
	participation := strings.TrimSpace(candidate.ParticipationType)
	if candidate.TeamSizeMax == 1 || (strings.Contains(participation, "个人") && !strings.Contains(participation, "团队")) {
		return 3
	}
	return 7
}

// IsLongTerm 判断赛事是否为长期训练型。known=false 表示时间信息不足以判定。
func IsLongTerm(candidate Candidate) (bool, bool) {
	var start, end *time.Time
	if candidate.RegistrationEnd != nil {
		end = candidate.RegistrationEnd
	} else if candidate.EventStart != nil {
		end = candidate.EventStart
	}
	if candidate.EventStart != nil {
		start = candidate.EventStart
	} else if candidate.RegistrationEnd != nil {
		start = candidate.RegistrationEnd
	}
	if start == nil || end == nil || !end.After(*start) {
		return false, false
	}
	return end.Sub(*start) >= 60*24*time.Hour, true
}

func searchableText(candidate Candidate) string {
	parts := []string{candidate.CompetitionID, candidate.ParticipationType, candidate.CategorySlug}
	parts = append(parts, candidate.Tags...)
	for _, cluster := range candidate.ClusterScope.Clusters {
		parts = append(parts, string(cluster))
	}
	return strings.ToLower(strings.Join(parts, " "))
}

func countTagHits(wanted []string, tags []string) int {
	offer := make(map[string]struct{}, len(tags))
	for _, tag := range tags {
		offer[NormalizeMajor(tag)] = struct{}{}
	}
	seen := make(map[string]struct{}, len(wanted))
	hit := 0
	for _, value := range wanted {
		key := NormalizeMajor(value)
		if key == "" {
			continue
		}
		if _, exists := seen[key]; exists {
			continue
		}
		if _, ok := offer[key]; ok {
			seen[key] = struct{}{}
			hit++
		}
	}
	return hit
}

// roleKeywords 与 handlers.competitionRoleKeywords 保持同一闭集语义。
var roleKeywords = map[string][]string{
	"developer": {"程序", "软件", "编程", "开发", "算法", "代码", "计算机"},
	"modeler":   {"建模", "数学模型", "仿真"},
	"hardware":  {"硬件", "电子", "嵌入式", "电路", "单片机"},
	"designer":  {"设计", "视觉", "交互", "艺术"},
	"writer":    {"文案", "写作", "策划", "商业计划书"},
	"presenter": {"答辩", "演讲", "路演", "展示"},
	"organizer": {"组织", "管理", "项目管理", "协调"},
}

func roleKeywordHit(role, text string) bool {
	for _, keyword := range roleKeywords[strings.TrimSpace(role)] {
		if strings.Contains(text, strings.ToLower(keyword)) {
			return true
		}
	}
	return false
}

func ratingRank(value string) int {
	order := map[string]int{"S": 6, "A": 5, "B+": 4, "B": 3, "B-": 2, "C": 1}
	return order[strings.TrimSpace(value)]
}

func categoryBridge(slug string) []Cluster {
	switch strings.TrimSpace(slug) {
	case "computer_ai":
		return []Cluster{"计算机类", "软件工程", "网络工程", "数据科学类", "智能科学类"}
	case "electronic_info":
		return []Cluster{"电子信息类", "通信工程", "集成电路相关", "微电子相关"}
	case "smart_manufacturing_vehicle":
		return []Cluster{"机械类", "车辆工程", "工业设计", "自动化类", "电气工程类", "机器人工程", "材料成型及控制工程"}
	case "art_design":
		return []Cluster{"视觉传达设计", "环境设计", "产品设计", "动画", "数字媒体相关", "工业设计"}
	case "business_economics":
		return []Cluster{"工商管理类", "工商管理", "市场营销", "会计学", "财务管理", "金融学", "经济学类", "国际经济与贸易", "电子商务", "管理科学与工程类"}
	case "math_science":
		return []Cluster{"数学类", "数学与应用数学", "统计学类"}
	case "materials_chem_env":
		return []Cluster{"材料类", "环境工程", "应用化学", "化学工程与工艺", "生命健康相关"}
	case "language_humanities":
		return []Cluster{"英语", "俄语", "翻译", "人文社科相关", "国际交流相关"}
	case "defense_security_other":
		return []Cluster{"工科相关专业"}
	default:
		return nil
	}
}

// tagBridge 把赛事方向标签桥接到专业簇。
var tagBridge = map[string][]Cluster{
	"计算机":   {"计算机类", "软件工程", "网络工程"},
	"算法与软件": {"计算机类", "软件工程", "数据科学类"},
	"电子信息":  {"电子信息类", "通信工程"},
	"芯片与通信": {"集成电路相关", "微电子相关", "通信工程"},
	"智能制造":  {"机械类", "自动化类", "车辆工程", "机器人工程"},
	"工程实践":  {"机械类", "材料成型及控制工程", "工程设计相关"},
	"艺术设计":  {"视觉传达设计", "环境设计", "产品设计", "动画", "工业设计"},
	"创意表达":  {"数字媒体相关", "动画", "视觉传达设计"},
	"经管商科":  {"工商管理类", "会计学", "金融学", "市场营销", "电子商务"},
	"案例与模拟": {"工商管理类", "管理科学与工程类"},
	"理学材料":  {"数学类", "材料类", "应用化学"},
	"化工环境":  {"化学工程与工艺", "环境工程", "应用化学"},
	"语言人文":  {"英语", "翻译", "人文社科相关"},
	"文化传播":  {"人文社科相关", "国际交流相关"},
	"数学建模":  {"数学类", "数学与应用数学", "统计学类"},
	"仿真决策":  {"数学类", "管理科学与工程类"},
}

// ClusterBridgeForDirection 把用户填的方向标签桥接到专业簇。
// 方向标签本身不是簇，需要这层桥接才能与赛事簇求交集。
func ClusterBridgeForDirection(direction string) []Cluster {
	return tagBridge[strings.TrimSpace(direction)]
}

// offerClusterSet 汇总赛事可提供的簇（含类别与标签桥接），用于偏好命中判定。
func offerClusterSet(candidate Candidate) map[Cluster]struct{} {
	result := make(map[Cluster]struct{}, len(candidate.ClusterScope.Clusters)+8)
	for _, value := range candidate.ClusterScope.Clusters {
		result[value] = struct{}{}
	}
	for _, value := range categoryBridge(candidate.CategorySlug) {
		result[value] = struct{}{}
	}
	for _, tag := range candidate.Tags {
		for _, value := range tagBridge[strings.TrimSpace(tag)] {
			result[value] = struct{}{}
		}
	}
	return result
}

// bridgedClusters 返回用户簇与赛事「类别/标签桥接」结果的交集。
func bridgedClusters(user []Cluster, candidate Candidate) []Cluster {
	if len(user) == 0 {
		return nil
	}
	offer := offerClusterSet(candidate)
	result := make([]Cluster, 0, len(user))
	for _, value := range user {
		if _, ok := offer[value]; ok {
			result = append(result, value)
		}
	}
	sort.Slice(result, func(i, j int) bool { return result[i] < result[j] })
	return result
}

func appendUnique(values []string, value string) []string {
	for _, existing := range values {
		if existing == value {
			return values
		}
	}
	return append(values, value)
}

func clamp(value, low, high int) int {
	if value < low {
		return low
	}
	if value > high {
		return high
	}
	return value
}

func minInt(left, right int) int {
	if left < right {
		return left
	}
	return right
}

func maxInt(left, right int) int {
	if left > right {
		return left
	}
	return right
}
