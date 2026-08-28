package handlers

import (
	"errors"
	"net/http"

	"github.com/gin-gonic/gin"
)

// SubmitDishPhotoV2 独立菜品投稿流程已退休。
//
// 现在通过食堂评价直接创建 active 菜品并立即关联 approved 实拍。
// POST /api/canteens/:id/dish-submissions
func (h *CanteenDishPhotoHandler) SubmitDishPhotoV2(c *gin.Context) {
	c.JSON(http.StatusGone, gin.H{
		"code":  "dish_submission_retired",
		"error": "菜品与实拍现已通过食堂评价提交，请更新客户端",
	})
}

// ResubmitDish 独立菜品重新审核流程已退休。
//
// POST /api/canteens/dishes/:dishId/resubmit
func (h *CanteenHandler) ResubmitDish(c *gin.Context) {
	c.JSON(http.StatusGone, gin.H{
		"code":  "dish_submission_retired",
		"error": "菜品与实拍现已通过食堂评价提交，请更新客户端",
	})
}

var errDishNameHiddenConflict = errors.New("dish name conflicts with hidden dish")

var errDishPendingLimit = errors.New("dish pending limit reached")

var errDishResubmitForbidden = errors.New("dish resubmit forbidden")

var errDishResubmitConflict = errors.New("dish resubmit conflict")

var errDishPhotoResubmitForbidden = errors.New("dish photo resubmit forbidden")
