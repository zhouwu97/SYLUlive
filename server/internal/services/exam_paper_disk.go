package services

func diskUsagePercent(total, available uint64) float64 {
	if total == 0 || available >= total {
		return 0
	}
	return float64(total-available) * 100 / float64(total)
}
