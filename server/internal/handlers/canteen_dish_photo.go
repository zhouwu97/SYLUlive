package handlers

import (
	"errors"

	"github.com/gin-gonic/gin"
	"gorm.io/gorm"
)

// errDishGalleryFull 该菜品已有 3 张实拍。
var errDishGalleryFull = errors.New("dish_gallery_full")

// MaxDishNameLength 菜名最大可见字符数（与客户端 maxLength: 40 对齐）。
const MaxDishNameLength = 40

// errDishPhotoAlreadyReviewed 该实拍已被审核处理。
var errDishPhotoAlreadyReviewed = errors.New("dish_photo_already_reviewed")

// CanteenDishPhotoHandler 菜品实拍投稿接口。
type CanteenDishPhotoHandler struct {
	db *gorm.DB
}

func NewCanteenDishPhotoHandler(db *gorm.DB) *CanteenDishPhotoHandler {
	return &CanteenDishPhotoHandler{db: db}
}

// SubmitDishPhoto 是旧客户端路径的兼容别名。
//
// 旧路径不能再保留“直接 active + approved + public”的历史行为，否则任何普通
// 学生都可以绕过菜品审核。统一转入 V2 pending 流程，保证旧客户端也不能绕过审核。
// POST /api/canteens/:canteenId/dish-photos
func (h *CanteenDishPhotoHandler) SubmitDishPhoto(c *gin.Context) {
	// 旧 URL 只承担协议兼容；新评价/投稿 API 使用 approved-only 容量语义。
	c.Set("legacy_dish_photo_submission", true)
	h.SubmitDishPhotoV2(c)
}

// errDishNotFound 菜品不存在或不属于该食堂。
var errDishNotFound = errors.New("dish not found")

// errInvalidDishName 菜名为空。
var errInvalidDishName = errors.New("invalid dish name")
