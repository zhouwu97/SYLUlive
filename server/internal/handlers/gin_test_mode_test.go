package handlers

import "github.com/gin-gonic/gin"

func init() {
	// Gin 模式是进程级配置，不能在并发请求辅助函数中反复写入。
	gin.SetMode(gin.TestMode)
}
