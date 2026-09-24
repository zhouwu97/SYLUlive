package middleware

import (
	"net/http"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/gin-gonic/gin"
)

const readAbuseLimiterMaxKeys = 10000

type readAbuseLimitEntry struct {
	windowStart time.Time
	count       int
	lastSeen    time.Time
}

// ReadAbuseRateLimitMiddleware 为高成本公开读取接口提供进程内的基础限流。
//
// 来源封禁只负责已确认的攻击来源，不能用来覆盖正常 GET 请求；这里按客户端 IP
// 和路由族限速，先把最容易被爬取和洪泛的读取入口挡在业务查询之前。部署多实例时
// 仍应在网关或共享限流层复用同一策略，本层负责单实例失守时的最后一道成本上限。
func ReadAbuseRateLimitMiddleware(limit int, window time.Duration, prefixes ...string) gin.HandlerFunc {
	if limit <= 0 {
		limit = 120
	}
	if window <= 0 {
		window = time.Minute
	}
	if len(prefixes) == 0 {
		prefixes = []string{"/api/posts", "/api/search", "/api/topics/search", "/api/topics/recommend"}
	}
	entries := make(map[string]readAbuseLimitEntry)
	var mu sync.Mutex

	return func(c *gin.Context) {
		if c.Request.Method != http.MethodGet && c.Request.Method != http.MethodHead {
			c.Next()
			return
		}
		prefix := readAbuseRoutePrefix(c.Request.URL.Path, prefixes)
		if prefix == "" {
			c.Next()
			return
		}
		clientIP := strings.TrimSpace(c.ClientIP())
		if clientIP == "" {
			clientIP = strings.TrimSpace(c.Request.RemoteAddr)
		}
		key := clientIP + "\n" + prefix
		now := time.Now()

		mu.Lock()
		if len(entries) >= readAbuseLimiterMaxKeys {
			for existingKey, entry := range entries {
				if now.Sub(entry.lastSeen) >= window {
					delete(entries, existingKey)
				}
			}
			if len(entries) >= readAbuseLimiterMaxKeys {
				// 新来源不应因为旧来源占满内存而绕过限流；淘汰最旧的一项，
				// 让内存上限稳定，同时保留最近来源的窗口状态。
				var oldestKey string
				var oldest time.Time
				for existingKey, entry := range entries {
					if oldestKey == "" || entry.lastSeen.Before(oldest) {
						oldestKey, oldest = existingKey, entry.lastSeen
					}
				}
				if oldestKey != "" {
					delete(entries, oldestKey)
				}
			}
		}
		entry := entries[key]
		if entry.windowStart.IsZero() || now.Sub(entry.windowStart) >= window {
			entry = readAbuseLimitEntry{windowStart: now}
		}
		entry.lastSeen = now
		if entry.count >= limit {
			entries[key] = entry
			mu.Unlock()
			c.Header("Retry-After", strconv.Itoa(int(maxDuration(window-now.Sub(entry.windowStart), time.Second).Seconds())))
			c.AbortWithStatusJSON(http.StatusTooManyRequests, gin.H{
				"code":    "read_rate_limited",
				"message": "读取请求过于频繁，请稍后再试",
			})
			return
		}
		entry.count++
		entries[key] = entry
		mu.Unlock()
		c.Next()
	}
}

func readAbuseRoutePrefix(path string, prefixes []string) string {
	for _, prefix := range prefixes {
		prefix = strings.TrimSuffix(strings.TrimSpace(prefix), "/")
		if prefix != "" && (path == prefix || strings.HasPrefix(path, prefix+"/")) {
			return prefix
		}
	}
	return ""
}

func maxDuration(value, minimum time.Duration) time.Duration {
	if value < minimum {
		return minimum
	}
	return value
}
