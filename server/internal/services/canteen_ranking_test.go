package services

import (
	"math"
	"testing"
)

// TestBayesianRatingScore 验证 Bayesian 公式在截图场景（个位评价数）下单调且可解释。
func TestBayesianRatingScore(t *testing.T) {
	const m = 5.0
	const globalMean = 4.0

	// 截图场景：A 4.6/5、B 3.8/4、C 4.3/3、D 4.3/3、E 4.0/3
	// 手算（m=5, C=4）：
	//   A = (5/10)*4.6 + (5/10)*4.0 = 4.30
	//   B = (4/9)*3.8 + (5/9)*4.0  = 3.911
	//   C = (3/8)*4.3 + (5/8)*4.0  = 4.1125
	//   D = 4.1125（与 C 同分，tie-break 由评价数/创建时间决定）
	//   E = (3/8)*4.0 + (5/8)*4.0  = 4.0
	// 期望可见即：A > C > D > E > B（B 因低分被挤到最后是可解释的）。
	cases := []struct {
		name      string
		average   float64
		count     float64
		wantScore float64
	}{
		{"A(4.6/5)", 4.6, 5, 4.30},
		{"B(3.8/4)", 3.8, 4, 3.911},
		{"C(4.3/3)", 4.3, 3, 4.1125},
		{"E(4.0/3)", 4.0, 3, 4.0},
	}
	got := map[string]float64{}
	for _, tc := range cases {
		s := BayesianRatingScore(tc.average, tc.count, globalMean, m)
		got[tc.name] = s
		if math.Abs(s-tc.wantScore) > 1e-3 {
			t.Fatalf("%s: got %.4f want %.4f", tc.name, s, tc.wantScore)
		}
	}
	// B 应严格小于 A（4.30 > 3.91）。
	if !(got["A(4.6/5)"] > got["B(3.8/4)"]) {
		t.Fatalf("expected A > B, got A=%.4f B=%.4f", got["A(4.6/5)"], got["B(3.8/4)"])
	}
	// C 应严格大于 E（更高平均分同评价数）。
	if !(got["C(4.3/3)"] > got["E(4.0/3)"]) {
		t.Fatalf("expected C > E, got C=%.4f E=%.4f", got["C(4.3/3)"], got["E(4.0/3)"])
	}
}

// TestBayesianRatingScoreUnrated 无评价食堂分数必须为 0，保证置底。
func TestBayesianRatingScoreUnrated(t *testing.T) {
	if got := BayesianRatingScore(5.0, 0, 4.0, 5.0); got != 0 {
		t.Fatalf("unrated should be 0, got %v", got)
	}
}

// TestBayesianRatingScoreShrinksSmallSample 小样本高分应向全局均值收缩，不会轻易榜首。
func TestBayesianRatingScoreShrinksSmallSample(t *testing.T) {
	const m = 5.0
	// 1 人 5 星 vs 20 人 4.5，全局均值 4.0。
	single := BayesianRatingScore(5.0, 1, 4.0, m)   // (1/6)*5+(5/6)*4 = 4.1667
	bulk := BayesianRatingScore(4.5, 20, 4.0, m)     // (20/25)*4.5+(5/25)*4 = 4.4
	if !(bulk > single) {
		t.Fatalf("expected bulk(%.4f) > single(%.4f), Bayesian 应优先大样本", bulk, single)
	}
}

// TestRatingConfidence 样本置信度阈值。
func TestRatingConfidence(t *testing.T) {
	cases := map[int]string{0: "low", 5: "low", 9: "low", 10: "medium", 49: "medium", 50: "high", 200: "high"}
	for count, want := range cases {
		if got := RatingConfidence(count); got != want {
			t.Fatalf("RatingConfidence(%d)=%q want %q", count, got, want)
		}
	}
}
