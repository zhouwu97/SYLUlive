package handlers

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"github.com/gin-gonic/gin"
	"gorm.io/gorm"
	"gorm.io/gorm/clause"
	"io"
	"net/http"
	"shenliyuan/internal/models"
	"strconv"
	"strings"
	"time"
)

type AcademicAccountConfigHandler struct{ db *gorm.DB }

func NewAcademicAccountConfigHandler(db *gorm.DB) *AcademicAccountConfigHandler {
	return &AcademicAccountConfigHandler{db: db}
}

func (h *AcademicAccountConfigHandler) List(c *gin.Context) {
	if !configUserMatches(c) {
		return
	}
	configs := make([]models.AcademicAccountConfig, 0)
	if err := h.db.Where("user_id = ?", c.GetUint("user_id")).Order("provider_id").Find(&configs).Error; err != nil {
		c.JSON(503, gin.H{"code": "CONFIG_UNAVAILABLE"})
		return
	}
	c.JSON(200, gin.H{"configs": configs})
}

var errConfigConflict = errors.New("config conflict")
var errConfigOperationReuse = errors.New("operation reused")

func (h *AcademicAccountConfigHandler) Mutate(c *gin.Context) {
	if !configUserMatches(c) {
		return
	}
	provider, err := models.ParseAcademicProviderID(c.Param("provider"))
	operation := strings.TrimSpace(c.GetHeader("Idempotency-Key"))
	if err != nil || operation == "" || len(operation) > 128 || strings.ContainsAny(operation, "\r\n") {
		c.JSON(400, gin.H{"code": "INVALID_CONFIG_OPERATION"})
		return
	}
	var input struct {
		StudentID        string  `json:"student_id"`
		ExpectedRevision *uint64 `json:"expected_revision"`
	}
	// 仅接受配置字段，拒绝密码、Cookie 等误传字段。
	decoder := json.NewDecoder(http.MaxBytesReader(c.Writer, c.Request.Body, 4096))
	decoder.DisallowUnknownFields()
	if decoder.Decode(&input) != nil || input.ExpectedRevision == nil {
		c.JSON(400, gin.H{"code": "INVALID_CONFIG"})
		return
	}
	var extra any
	if decoder.Decode(&extra) != io.EOF {
		c.JSON(400, gin.H{"code": "INVALID_CONFIG"})
		return
	}
	deleted := c.Request.Method == http.MethodDelete
	if !deleted {
		if _, err := models.ValidateAcademicStudentID(input.StudentID); err != nil {
			c.JSON(400, gin.H{"code": "INVALID_STUDENT_ID"})
			return
		}
	}
	canonical, _ := json.Marshal([]any{string(provider), deleted, input.StudentID, *input.ExpectedRevision})
	digest := sha256.Sum256(canonical)
	hash := hex.EncodeToString(digest[:])
	userID := c.GetUint("user_id")
	var result models.AcademicAccountConfig
	err = h.db.Transaction(func(tx *gorm.DB) error {
		// 锁定所属用户，使同一用户的首次创建和幂等消费也有事务顺序。
		var owner models.User
		if err := tx.Clauses(clause.Locking{Strength: "UPDATE"}).Select("id").First(&owner, userID).Error; err != nil {
			return err
		}
		var receipt models.AcademicConfigReceipt
		err := tx.Where("user_id = ? AND operation_id = ?", userID, operation).First(&receipt).Error
		if err == nil {
			if receipt.RequestHash != hash {
				return errConfigOperationReuse
			}
			return json.Unmarshal([]byte(receipt.Result), &result)
		}
		if !errors.Is(err, gorm.ErrRecordNotFound) {
			return err
		}
		err = tx.Where("user_id = ? AND provider_id = ?", userID, string(provider)).First(&result).Error
		if err != nil && !errors.Is(err, gorm.ErrRecordNotFound) {
			return err
		}
		if result.Revision != *input.ExpectedRevision {
			return errConfigConflict
		}
		result.UserID = userID
		result.ProviderID = string(provider)
		result.Revision++
		result.State = "active"
		result.DeletedAt = nil
		if deleted {
			now := time.Now().UTC()
			result.State = "deleted"
			result.StudentID = ""
			result.DeletedAt = &now
		} else {
			result.StudentID = input.StudentID
		}
		if err := tx.Save(&result).Error; err != nil {
			return err
		}
		payload, err := json.Marshal(result)
		if err != nil {
			return err
		}
		return tx.Create(&models.AcademicConfigReceipt{UserID: userID, OperationID: operation, RequestHash: hash, Result: string(payload)}).Error
	})
	if errors.Is(err, errConfigConflict) {
		c.JSON(409, gin.H{"code": "CONFIG_CONFLICT", "config": result})
		return
	}
	if errors.Is(err, errConfigOperationReuse) {
		c.JSON(409, gin.H{"code": "OPERATION_REUSED"})
		return
	}
	if err != nil {
		c.JSON(503, gin.H{"code": "CONFIG_UNAVAILABLE"})
		return
	}
	c.JSON(200, gin.H{"config": result})
}

// FrozenAcademicIdentityMutation 保留历史登录查询，停止服务器接收学校认证材料。
func FrozenAcademicIdentityMutation(c *gin.Context) {
	c.JSON(http.StatusGone, gin.H{"code": "ACADEMIC_IDENTITY_FROZEN", "message": "请升级客户端，在本设备连接教务"})
}

// 校验发起时的 App 用户，防止异步队列或浏览器 Cookie 在切号后把旧 Outbox 写给新用户。
func configUserMatches(c *gin.Context) bool {
	expected := c.GetHeader("X-Expected-App-User")
	if expected != "" && expected != strconv.FormatUint(uint64(c.GetUint("user_id")), 10) {
		c.JSON(http.StatusConflict, gin.H{"code": "APP_USER_CHANGED"})
		return false
	}
	return true
}
