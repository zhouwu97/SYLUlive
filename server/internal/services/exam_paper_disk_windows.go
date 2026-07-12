//go:build windows

package services

import (
	"fmt"

	"golang.org/x/sys/windows"
)

// ExamPaperDiskUsagePercent 返回目标目录所在卷的已用空间百分比。
func ExamPaperDiskUsagePercent(path string) (float64, error) {
	pathPointer, err := windows.UTF16PtrFromString(path)
	if err != nil {
		return 0, fmt.Errorf("解析存储目录失败: %w", err)
	}
	var available uint64
	var total uint64
	var free uint64
	if err := windows.GetDiskFreeSpaceEx(pathPointer, &available, &total, &free); err != nil {
		return 0, fmt.Errorf("读取磁盘空间失败: %w", err)
	}
	if total == 0 {
		return 0, fmt.Errorf("磁盘总容量为零")
	}
	return diskUsagePercent(total, available), nil
}
