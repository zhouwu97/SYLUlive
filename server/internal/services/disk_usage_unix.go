//go:build aix || darwin || dragonfly || freebsd || linux || netbsd || openbsd || solaris

package services

import "golang.org/x/sys/unix"

// readDiskUsage 使用文件所在文件系统的统计值，避免仅统计 uploads 子目录时漏掉
// PostgreSQL、日志等同样占用根分区的内容。
func readDiskUsage(path string) (DiskUsageSnapshot, error) {
	var stat unix.Statfs_t
	if err := unix.Statfs(path, &stat); err != nil {
		return DiskUsageSnapshot{}, err
	}
	blockSize := uint64(stat.Bsize)
	total := uint64(stat.Blocks) * blockSize
	free := uint64(stat.Bavail) * blockSize
	used := total - free
	percent := float64(0)
	if total > 0 {
		percent = float64(used) * 100 / float64(total)
	}
	return DiskUsageSnapshot{TotalBytes: total, FreeBytes: free, UsedPercent: percent}, nil
}
