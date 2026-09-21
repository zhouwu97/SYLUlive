package handlers

import (
	"encoding/json"
	"fmt"
	"github.com/gin-gonic/gin"
	"net/http"
	"shenliyuan/internal/ai"
)

func (h *AIRuntimeHandler) LocalAnalysis(c *gin.Context) {
	var input ai.LocalAnalysisRequest
	if err := decodeStrictJSON(c, &input, 8<<10); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"code": "invalid_summary", "message": "个人摘要格式无效"})
		return
	}
	streaming := false
	emit := func(event string, payload interface{}) error {
		if !streaming {
			c.Header("Content-Type", "text/event-stream; charset=utf-8")
			c.Header("Cache-Control", "no-store")
			c.Header("X-Accel-Buffering", "no")
			streaming = true
		}
		encoded, err := json.Marshal(gin.H{"payload": payload})
		if err != nil {
			return err
		}
		_, err = fmt.Fprintf(c.Writer, "event: %s\ndata: %s\n\n", event, encoded)
		c.Writer.Flush()
		return err
	}
	if err := h.runtime.LocalAnalysis(c.Request.Context(), c.GetUint("user_id"), input, emit); err != nil {
		if streaming {
			_ = emit("run.failed", gin.H{"message": "个人分析未完成，请重新确认摘要后重试"})
		} else {
			writeAIRuntimeError(c, err)
		}
	}
}
func (h *AIRuntimeHandler) LocalAnalysisSettings(c *gin.Context) {
	c.JSON(http.StatusOK, gin.H{"models": []string{h.runtime.LocalAnalysisModel()}, "default_model": h.runtime.LocalAnalysisModel(), "summary_types": []string{"grade_statistics"}})
}
