// Package competitionmatching 提供竞赛候选的专业匹配与打分。
//
// 设计约束（来自既有约定，不得违反）：
//   - 本包是纯函数包，不依赖 HTTP、数据库或时钟以外的一切外部状态，
//     以便离线用同一份代码复算线上结果（黄金用例可验证的前提）。
//   - 对外响应不暴露伪精确总分（dto/competition_candidate.go:39），
//     分值只用于内部排序，向学生只暴露离散档位与离散匹配维度。
//   - 匹配只做闭集标签的精确集合交集，不做全文字符串包含或模糊匹配。
package competitionmatching

import (
	"regexp"
	"strings"
)

// Cluster 是专业簇标签。词表以线上目录 eligible_majors 的实际取值为准，
// 是闭集：目录侧只能使用这些标签，画像侧通过标准专业名映射到这些标签。
type Cluster string

// broadSuffix 标识口径过宽的标签。这些标签能覆盖大量赛事，
// 命中它们不足以说明真实相关性，因此在打分时降权而不是完全采纳。
const broadSuffix = "相关"

// broadClusterExtra 是口径宽但不符合「相关」后缀特例的标签。
var broadClusterExtra = map[Cluster]struct{}{
	"工科相关专业": {},
}

// StandardClusters 是目录侧在用的全部专业簇标签（53 项）。
// 新增目录标签时必须同步此表，否则 resolveEventClusters 会把它记为未知标签。
var StandardClusters = []Cluster{
	// 计算机与信息
	"计算机类", "软件工程", "网络工程", "数据科学类", "智能科学类",
	"电子信息类", "通信工程", "集成电路相关", "微电子相关",
	// 自动化与电气
	"自动化类", "自动化相关", "电气工程类", "机器人工程",
	// 机械与车辆
	"机械类", "车辆工程", "工业设计", "工程设计相关", "材料成型及控制工程",
	// 材料与环境化工
	"材料类", "生命健康相关", "金属材料工程相关",
	"环境工程", "应用化学", "化学工程与工艺", "化学相关",
	// 数理
	"数学类", "数学与应用数学", "统计学类",
	// 经管商科
	"工商管理类", "工商管理", "市场营销", "会计学", "财务管理",
	"金融学", "经济学类", "经济学相关", "国际经济与贸易", "电子商务",
	"管理科学与工程类", "物流管理相关",
	// 艺术设计
	"视觉传达设计", "环境设计", "产品设计", "动画", "数字媒体相关",
	// 外语人文
	"英语", "俄语", "翻译", "国际交流相关", "人文社科相关", "思想政治教育相关",
	// 交通与其他
	"交通运输相关", "工科相关专业",
}

var clusterSet = func() map[Cluster]struct{} {
	result := make(map[Cluster]struct{}, len(StandardClusters))
	for _, cluster := range StandardClusters {
		result[cluster] = struct{}{}
	}
	return result
}()

// IsStandardCluster 判断标签是否为词表内的合法簇。
func IsStandardCluster(value string) bool {
	_, ok := clusterSet[Cluster(strings.TrimSpace(value))]
	return ok
}

// IsBroadCluster 判断簇是否为宽口径标签。宽标签命中只给降权分。
func IsBroadCluster(cluster Cluster) bool {
	if _, ok := broadClusterExtra[cluster]; ok {
		return true
	}
	return strings.HasSuffix(string(cluster), broadSuffix)
}

// parentheticalPattern 去除专业名里的方向后缀，例如
// 「计算机科学与技术（嵌入式）」→「计算机科学与技术」。
// 教务画像里的专业名常带此类后缀，不归一化会导致映射整条失效。
var parentheticalPattern = regexp.MustCompile(`[（(][^）)]*[）)]`)

// whitespacePattern 合并连续空白，兼容教务系统导出的不规则空格。
var whitespacePattern = regexp.MustCompile(`\s+`)

// NormalizeMajor 把自由文本专业名归一为可比较的键。
// 与 handlers.normalizeAcademicName 保持同样的下界行为（去标点、转小写），
// 但额外处理括号后缀——这是画像侧匹配失败的主要来源之一。
func NormalizeMajor(value string) string {
	value = parentheticalPattern.ReplaceAllString(value, "")
	value = strings.TrimFunc(strings.TrimSpace(value), func(r rune) bool {
		return strings.ContainsRune("·-—_/、,，.。", r)
	})
	return whitespacePattern.ReplaceAllString(strings.ToLower(value), "")
}

// majorAliases 把教务系统的写法差异归一到标准专业名。
// 键与值都必须先经过 NormalizeMajor。
var majorAliases = map[string]string{
	"计算机科学与技术专业": "计算机科学与技术",
	"计算机科学":      "计算机科学与技术",
	"软件工程专业":     "软件工程",
	"电子信息工程专业":   "电子信息工程",
	"机械设计制造及自动化": "机械设计制造及其自动化",
	"机械设计及其自动化":  "机械设计制造及其自动化",
	"电气工程自动化":    "电气工程及其自动化",
	"信息与计算科学专业":  "信息与计算科学",
	"思想政治教育专业":   "思想政治教育",
}

// standardMajorClusters 是「标准专业名 → 专业簇」的种子映射。
//
// 性质说明：本表按目录实测的 53 个簇标签反推，是待教务名册核对的草案
// （见 docs/plans/competition-recommendation-plan.md 附录 B）。
// 上线前必须由教务名册覆盖，并通过 academic_majors 表持久化以便运营维护；
// 在此之前的硬编码仅用于让链路可运行、可测试。
var standardMajorClusters = map[string][]Cluster{
	// 信息科学与工程学院
	"计算机科学与技术":    {"计算机类"},
	"软件工程":        {"计算机类", "软件工程"},
	"网络工程":        {"计算机类", "网络工程"},
	"物联网工程":       {"计算机类", "网络工程"},
	"数据科学与大数据技术":  {"数据科学类", "计算机类"},
	"人工智能":        {"智能科学类", "数据科学类", "计算机类"},
	"智能科学与技术":     {"智能科学类", "计算机类"},
	"电子信息工程":      {"电子信息类"},
	"通信工程":        {"通信工程", "电子信息类"},
	"电子科学与技术":     {"电子信息类", "微电子相关"},
	"集成电路设计与集成系统": {"集成电路相关", "电子信息类"},
	"信息管理与信息系统":   {"管理科学与工程类", "计算机类"},
	// 自动化与电气工程学院
	"自动化":       {"自动化类", "自动化相关"},
	"电气工程及其自动化": {"电气工程类", "自动化类"},
	"机器人工程":     {"机器人工程", "自动化类"},
	"测控技术与仪器":   {"自动化类"},
	"探测制导与控制技术": {"自动化类", "电子信息类"},
	// 机械工程学院 / 装备工程学院
	"机械设计制造及其自动化": {"机械类", "工程设计相关"},
	"机械电子工程":      {"机械类", "自动化类"},
	"材料成型及控制工程":   {"材料类", "材料成型及控制工程", "机械类"},
	"工业设计":        {"工业设计", "工程设计相关", "产品设计"},
	"过程装备与控制工程":   {"机械类"},
	"焊接技术与工程":     {"材料类", "机械类"},
	"武器系统与工程":     {"机械类", "工科相关专业"},
	"弹药工程与爆炸技术":   {"机械类", "工科相关专业"},
	// 汽车与交通学院
	"车辆工程":   {"车辆工程", "机械类"},
	"汽车服务工程": {"车辆工程", "机械类"},
	"装甲车辆工程": {"车辆工程", "机械类"},
	"交通运输":   {"交通运输相关", "工科相关专业"},
	"物流管理":   {"物流管理相关", "管理科学与工程类"},
	// 材料科学与工程学院
	"材料科学与工程":   {"材料类"},
	"金属材料工程":    {"材料类", "金属材料工程相关"},
	"无机非金属材料工程": {"材料类"},
	"高分子材料与工程":  {"材料类"},
	"复合材料与工程":   {"材料类"},
	// 环境与化学工程学院
	"化学工程与工艺": {"化学工程与工艺", "化学相关"},
	"应用化学":    {"应用化学", "化学相关"},
	"环境工程":    {"环境工程"},
	"安全工程":    {"环境工程", "工科相关专业"},
	"制药工程":    {"化学工程与工艺", "生命健康相关"},
	// 理学院
	"数学与应用数学":   {"数学与应用数学", "数学类"},
	"信息与计算科学":   {"数学类", "数据科学类"},
	"应用统计学":     {"统计学类", "数学类"},
	"应用物理学":     {"工科相关专业"},
	"光电信息科学与工程": {"电子信息类", "工科相关专业"},
	// 经济管理学院
	"工商管理":    {"工商管理类", "工商管理"},
	"市场营销":    {"市场营销", "工商管理类"},
	"会计学":     {"会计学", "工商管理类"},
	"财务管理":    {"财务管理", "会计学"},
	"金融学":     {"金融学", "经济学类"},
	"经济学":     {"经济学类", "经济学相关"},
	"国际经济与贸易": {"国际经济与贸易", "经济学类"},
	"电子商务":    {"电子商务", "工商管理类"},
	// 艺术设计学院
	"视觉传达设计": {"视觉传达设计", "数字媒体相关"},
	"环境设计":   {"环境设计"},
	"产品设计":   {"产品设计", "工业设计"},
	"动画":     {"动画", "数字媒体相关"},
	"数字媒体艺术": {"数字媒体相关", "动画", "视觉传达设计"},
	// 外国语学院 / 马克思主义学院
	"英语":     {"英语", "翻译"},
	"俄语":     {"俄语", "翻译"},
	"翻译":     {"翻译", "英语", "国际交流相关"},
	"思想政治教育": {"思想政治教育相关", "人文社科相关"},
}

// broadMajorSubstring 处理教务名册里未逐一登记的专业名。
// 只做「前缀/关键词 → 簇」的粗归类，命中后按宽口径处理。
// 这是覆盖率的兜底，不是主路径：主路径必须靠 standardMajorClusters + 名册。
var broadMajorSubstring = []struct {
	keyword string
	cluster Cluster
}{
	{"计算机", "计算机类"},
	{"软件", "软件工程"},
	{"网络", "网络工程"},
	{"数据", "数据科学类"},
	{"智能", "智能科学类"},
	{"电子", "电子信息类"},
	{"通信", "通信工程"},
	{"集成电路", "集成电路相关"},
	{"自动化", "自动化类"},
	{"电气", "电气工程类"},
	{"机器人", "机器人工程"},
	{"机械", "机械类"},
	{"车辆", "车辆工程"},
	{"汽车", "车辆工程"},
	{"材料", "材料类"},
	{"环境", "环境工程"},
	{"化学", "应用化学"},
	{"数学", "数学类"},
	{"统计", "统计学类"},
	{"会计", "会计学"},
	{"财务", "财务管理"},
	{"金融", "金融学"},
	{"经济", "经济学类"},
	{"贸易", "国际经济与贸易"},
	{"营销", "市场营销"},
	{"工商", "工商管理类"},
	{"管理", "管理科学与工程类"},
	{"电子商务", "电子商务"},
	{"设计", "工业设计"},
	{"动画", "动画"},
	{"英语", "英语"},
	{"俄语", "俄语"},
	{"翻译", "翻译"},
	{"物流", "物流管理相关"},
	{"交通", "交通运输相关"},
	{"安全", "环境工程"},
}

// LookupMajorClusters 返回标准专业名对应的专业簇。
//
// 返回值 mapped 为 false 表示该专业名既不在种子映射里，也无法粗归类——
// 调用方必须把这种情况暴露成可见的缺口（reason_code=cluster_unmapped），
// 不允许静默落入通用池，否则「某些专业永远匹配不到」会以无声方式复发。
func LookupMajorClusters(major string) (clusters []Cluster, mapped bool) {
	key := NormalizeMajor(major)
	if key == "" {
		return nil, false
	}
	if canonical, ok := majorAliases[key]; ok {
		key = canonical
	}
	if values, ok := standardMajorClusters[key]; ok {
		return dedupeClusters(values), true
	}
	for _, rule := range broadMajorSubstring {
		if strings.Contains(key, rule.keyword) {
			return []Cluster{rule.cluster}, true
		}
	}
	return nil, false
}

// dedupeClusters 去重并保持稳定顺序，保证打分结果可复现。
func dedupeClusters(values []Cluster) []Cluster {
	seen := make(map[Cluster]struct{}, len(values))
	result := make([]Cluster, 0, len(values))
	for _, value := range values {
		if _, exists := seen[value]; exists {
			continue
		}
		seen[value] = struct{}{}
		result = append(result, value)
	}
	return result
}
