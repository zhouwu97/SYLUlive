//go:build !windows

package services

import (
	"fmt"
	"syscall"
)

// ExamPaperDiskUsagePercent 返回目标目录所在文件系统的已用空间百分比。
func ExamPaperDiskUsagePercent(path string) (float64, error) {
	var stat syscall.Statfs_t
	if err := syscall.Statfs(path, &stat); err != nil {
		return 0, fmt.Errorf("读取磁盘空间失败: %w", err)
	}
	total := uint64(stat.Blocks) * uint64(stat.Bsize)
	free := uint64(stat.Bavail) * uint64(stat.Bsize)
	if total == 0 {
		return 0, fmt.Errorf("磁盘总容量为零")
	}
	return diskUsagePercent(total, free), nil
}
