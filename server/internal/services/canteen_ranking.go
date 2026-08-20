package services

// 食堂排行榜算法集中地。纯函数便于单元测试，避免把公式埋在 handler 的 SQL 字符串里。

// BayesianPriorWeight Bayesian 排名的先验权重 m。
// 先验权重越高，样本越少时越向全局均值收缩。
const BayesianPriorWeight = 5.0

// BayesianRatingScore 计算某食堂的 Bayesian 加权评分。
//
//	score = (n/(n+m)) * R + (m/(n+m)) * C
//
// R=该店平均分，n=该店评价数，C=全体已评价食堂的平均分(globalMean)，m=先验权重 priorWeight。
// 无评价（n<=0）返回 0，保证无评价食堂永不参与中上排位。
func BayesianRatingScore(average, count, globalMean, priorWeight float64) float64 {
	if count <= 0 {
		return 0
	}
	w := count + priorWeight
	return (count/w)*average + (priorWeight/w)*globalMean
}

// RatingConfidence 按评价数返回样本置信度标签（low/medium/high）。
func RatingConfidence(count int) string {
	switch {
	case count < 10:
		return "low"
	case count < 50:
		return "medium"
	default:
		return "high"
	}
}

// RatingConfidenceEffective 根据诚信加权后的有效样本量返回置信度，避免把低诚信
// 用户的原始 reviewer_count 当成与满权重样本等价。
func RatingConfidenceEffective(effectiveSample float64) string {
	switch {
	case effectiveSample < 10:
		return "low"
	case effectiveSample < 50:
		return "medium"
	default:
		return "high"
	}
}

// BayesianScoreTo100 将 1~5 分尺度的加权得分转为 0~100 综合分。
func BayesianScoreTo100(rawScore float64) float64 {
	if rawScore <= 0 {
		return 0
	}
	score100 := rawScore * 20.0
	if score100 > 100.0 {
		score100 = 100.0
	}
	return score100
}
