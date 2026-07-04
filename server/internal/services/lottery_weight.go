package services

func CalculateUserLevel(exp int) int {
	if exp >= 8000 {
		return 8
	}
	if exp >= 5000 {
		return 7
	}
	if exp >= 2500 {
		return 6
	}
	if exp >= 1000 {
		return 5
	}
	if exp >= 500 {
		return 4
	}
	if exp >= 150 {
		return 3
	}
	if exp >= 50 {
		return 2
	}
	return 1
}

func CalculateLotteryWeightByLevel(exp int) int {
	return CalculateUserLevel(exp)
}
