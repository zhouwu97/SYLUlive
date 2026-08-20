package services

import (
	"sort"
	"time"

	"shenliyuan/internal/models"
)

// 店铺五维评分权重，服务端是唯一权威来源。
const (
	TasteWeight   = 0.35
	ValueWeight   = 0.20
	QueueWeight   = 0.15
	HygieneWeight = 0.20
	ServiceWeight = 0.10
)

// 菜品三维评分权重。店铺的排队、服务、卫生永远不进入菜品评分。
const (
	DishTasteWeight   = 0.60
	DishValueWeight   = 0.25
	DishPortionWeight = 0.15
)

var recentReviewWeights = []float64{0.60, 0.30, 0.10}

// VisitScores 是一次店铺到店评价的五维分数。
type VisitScores struct {
	Taste   int
	Value   int
	Queue   int
	Hygiene int
	Service int
}

// DishScores 是一次菜品评价的三维分数。
type DishScores struct {
	Taste   int
	Value   int
	Portion int
}

// ValidateVisitScores 校验客户端提交的五维评分。
func ValidateVisitScores(s VisitScores) bool {
	return validScore(s.Taste) && validScore(s.Value) && validScore(s.Queue) &&
		validScore(s.Hygiene) && validScore(s.Service)
}

// ValidateDishScores 校验客户端提交的菜品评分。
func ValidateDishScores(s DishScores) bool {
	return validScore(s.Taste) && validScore(s.Value) && validScore(s.Portion)
}

func validScore(score int) bool { return score >= 1 && score <= 5 }

// ComputeVisitOverall 按固定权重计算一次店铺体验综合分。
func ComputeVisitOverall(s VisitScores) float64 {
	return float64(s.Taste)*TasteWeight +
		float64(s.Value)*ValueWeight +
		float64(s.Queue)*QueueWeight +
		float64(s.Hygiene)*HygieneWeight +
		float64(s.Service)*ServiceWeight
}

// ComputeDishOverall 按固定权重计算一次菜品体验综合分。
func ComputeDishOverall(s DishScores) float64 {
	return float64(s.Taste)*DishTasteWeight +
		float64(s.Value)*DishValueWeight +
		float64(s.Portion)*DishPortionWeight
}

// EffectiveUserRating 是最近三次到店事件按 60/30/10 归一后的用户有效摘要。
type EffectiveUserRating struct {
	Overall float64
	Taste   float64
	Value   float64
	Queue   float64
	Hygiene float64
	Service float64
	// TotalEventCount 是该用户的全部 active 到店事件数，包含历史 Legacy 事件。
	TotalEventCount int
	// UsedEventCount 是实际进入最近 3 条 60/30/10 评分的 V2 事件数。
	UsedEventCount int
	// EventCount 保留给旧的内部调用方，语义等同 UsedEventCount；新代码必须使用上面两个字段。
	EventCount      int
	LatestEventID   uint
	LatestCreatedAt time.Time
}

// ComputeEffectiveUserRating 只读取 active 事件，调用方可传入任意顺序。
func ComputeEffectiveUserRating(events []models.CanteenReviewEvent) EffectiveUserRating {
	active := make([]models.CanteenReviewEvent, 0, len(events))
	for _, event := range events {
		if event.Status == "" || event.Status == models.ReviewEventStatusActive {
			active = append(active, event)
		}
	}
	totalEventCount := len(active)
	// ScoreVersion=1 是从旧 /rate 摘要迁移出的历史事件，不含真实五维评分，
	// 不能进入 V2 有效评分；0 兼容早期 V2 数据/单测中未显式填写的默认值。
	effectiveEvents := make([]models.CanteenReviewEvent, 0, len(active))
	for _, event := range active {
		if event.ScoreVersion == 0 || event.ScoreVersion >= 2 {
			effectiveEvents = append(effectiveEvents, event)
		}
	}
	active = effectiveEvents
	sort.SliceStable(active, func(i, j int) bool {
		if active[i].CreatedAt.Equal(active[j].CreatedAt) {
			return active[i].ID > active[j].ID
		}
		return active[i].CreatedAt.After(active[j].CreatedAt)
	})
	if len(active) > len(recentReviewWeights) {
		active = active[:len(recentReviewWeights)]
	}

	var result EffectiveUserRating
	result.TotalEventCount = totalEventCount
	if len(active) == 0 {
		return result
	}
	weightSum := 0.0
	for i, event := range active {
		weight := recentReviewWeights[i]
		weightSum += weight
		overall := event.OverallScore
		if overall <= 0 {
			overall = ComputeVisitOverall(VisitScores{
				Taste: event.TasteScore, Value: event.ValueScore, Queue: event.QueueScore,
				Hygiene: event.HygieneScore, Service: event.ServiceScore,
			})
		}
		result.Overall += overall * weight
		result.Taste += float64(event.TasteScore) * weight
		result.Value += float64(event.ValueScore) * weight
		result.Queue += float64(event.QueueScore) * weight
		result.Hygiene += float64(event.HygieneScore) * weight
		result.Service += float64(event.ServiceScore) * weight
		if i == 0 {
			result.LatestEventID = event.ID
			result.LatestCreatedAt = event.CreatedAt
		}
	}
	result.Overall /= weightSum
	result.Taste /= weightSum
	result.Value /= weightSum
	result.Queue /= weightSum
	result.Hygiene /= weightSum
	result.Service /= weightSum
	result.UsedEventCount = len(active)
	result.EventCount = result.UsedEventCount
	return result
}

// ComputeCreditWeight 将诚信度映射到 [0.5, 1.0]，避免低诚信用户完全失去发言权。
func ComputeCreditWeight(creditScore int) float64 {
	if creditScore < 0 {
		creditScore = 0
	}
	if creditScore > 100 {
		creditScore = 100
	}
	return 0.5 + 0.5*float64(creditScore)/100
}

// UserRatingSample 是店铺聚合的一个用户有效样本。
type UserRatingSample struct {
	Overall float64
	Taste   float64
	Value   float64
	Queue   float64
	Hygiene float64
	Service float64
	Weight  float64
	// HasDimensions=false 的 Legacy 样本只参与综合分，不参与五维分母。
	HasDimensions bool
}

type CanteenAggregate struct {
	AverageScore             float64
	TasteScore               float64
	ValueScore               float64
	QueueScore               float64
	HygieneScore             float64
	ServiceScore             float64
	ReviewerCount            int
	EffectiveSample          float64
	DimensionEffectiveSample float64
}

// ComputeCanteenAggregate 每个用户最多贡献一个样本，并按诚信权重聚合。
func ComputeCanteenAggregate(samples []UserRatingSample) CanteenAggregate {
	var result CanteenAggregate
	for _, sample := range samples {
		if sample.Weight <= 0 {
			sample.Weight = 1
		}
		result.AverageScore += sample.Overall * sample.Weight
		result.EffectiveSample += sample.Weight
		result.ReviewerCount++
		if sample.HasDimensions {
			result.TasteScore += sample.Taste * sample.Weight
			result.ValueScore += sample.Value * sample.Weight
			result.QueueScore += sample.Queue * sample.Weight
			result.HygieneScore += sample.Hygiene * sample.Weight
			result.ServiceScore += sample.Service * sample.Weight
			result.DimensionEffectiveSample += sample.Weight
		}
	}
	if result.EffectiveSample == 0 {
		return result
	}
	result.AverageScore /= result.EffectiveSample
	if result.DimensionEffectiveSample > 0 {
		result.TasteScore /= result.DimensionEffectiveSample
		result.ValueScore /= result.DimensionEffectiveSample
		result.QueueScore /= result.DimensionEffectiveSample
		result.HygieneScore /= result.DimensionEffectiveSample
		result.ServiceScore /= result.DimensionEffectiveSample
	}
	return result
}

type DishRatingSample struct {
	Overall float64
	Taste   float64
	Value   float64
	Portion float64
	Weight  float64
}

type DishAggregate struct {
	AverageScore    float64
	TasteScore      float64
	ValueScore      float64
	PortionScore    float64
	ReviewerCount   int
	EffectiveSample float64
}

// ComputeDishAggregate 菜品聚合只处理菜品三维样本。
func ComputeDishAggregate(samples []DishRatingSample) DishAggregate {
	var result DishAggregate
	for _, sample := range samples {
		if sample.Weight <= 0 {
			sample.Weight = 1
		}
		result.AverageScore += sample.Overall * sample.Weight
		result.TasteScore += sample.Taste * sample.Weight
		result.ValueScore += sample.Value * sample.Weight
		result.PortionScore += sample.Portion * sample.Weight
		result.EffectiveSample += sample.Weight
		result.ReviewerCount++
	}
	if result.EffectiveSample == 0 {
		return result
	}
	result.AverageScore /= result.EffectiveSample
	result.TasteScore /= result.EffectiveSample
	result.ValueScore /= result.EffectiveSample
	result.PortionScore /= result.EffectiveSample
	return result
}
