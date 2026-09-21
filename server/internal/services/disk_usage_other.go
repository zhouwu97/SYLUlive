//go:build windows || plan9 || js || wasip1

package services

import "fmt"

func readDiskUsage(path string) (DiskUsageSnapshot, error) {
	return DiskUsageSnapshot{}, fmt.Errorf("当前平台不支持文件系统容量统计: %s", path)
}
