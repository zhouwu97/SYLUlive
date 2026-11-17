package handlers

import (
	"fmt"
	"net/http"
	"strings"
	"testing"

	"github.com/gin-gonic/gin"
	"shenliyuan/internal/models"
)

func TestArchivedCanteenMaintenanceRequiresCurrentSuperAdmin(t *testing.T) {
	for _, role := range []models.Role{models.RoleUser, models.RoleAdmin, models.RoleSuperAdmin} {
		for _, action := range []string{"info", "image", "tags", "dish", "merge", "photo", "cover", "online", "delete"} {
			t.Run(string(role)+"/"+action, func(t *testing.T) {
				h, canteen, actor := prepareReviewV2DB(t)
				if err := h.db.Model(&actor).Update("role", role).Error; err != nil {
					t.Fatal(err)
				}
				if err := h.db.Model(&canteen).Update("operating_status", models.CanteenOperatingOffline).Error; err != nil {
					t.Fatal(err)
				}
				dish := models.CanteenDish{CanteenID: canteen.ID, Name: "原菜品", NormalizedName: "原菜品", Status: models.DishStatusActive, CreatedBy: actor.ID}
				target := models.CanteenDish{CanteenID: canteen.ID, Name: "目标菜品", NormalizedName: "目标菜品", Status: models.DishStatusActive, CreatedBy: actor.ID}
				if err := h.db.Create(&dish).Error; err != nil {
					t.Fatal(err)
				}
				if err := h.db.Create(&target).Error; err != nil {
					t.Fatal(err)
				}
				file := models.File{Hash: "archive-permission", Path: "/uploads/archive-permission.png", Size: 1, MimeType: "image/png", UploaderID: actor.ID, Status: "active", AccessScope: models.FileAccessPublic}
				if err := h.db.Create(&file).Error; err != nil {
					t.Fatal(err)
				}
				photo := models.CanteenDishPhoto{DishID: dish.ID, FileID: file.ID, UserID: actor.ID, Status: models.DishPhotoStatusApproved}
				if err := h.db.Create(&photo).Error; err != nil {
					t.Fatal(err)
				}
				dh := NewCanteenDishPhotoAdminHandler(h.db)
				fn, method, param, body := gin.HandlerFunc(h.AdminUpdateCanteen), http.MethodPatch, mapParams("id", fmt.Sprint(canteen.ID)), `{"name":"修改后的食堂"}`
				switch action {
				case "image":
					fn, method, body = h.UpdateImage, http.MethodPut, `{"image":"/uploads/archive-permission.png"}`
				case "tags":
					fn, method, body = h.UpdateDisplayTags, http.MethodPut, `{"location_area":"一食堂","location_floor":"一楼","tags":[]}`
				case "dish":
					fn, param, body = dh.AdminUpdateDish, mapParams("dishId", fmt.Sprint(dish.ID)), `{"name":"修改后的菜品"}`
				case "merge":
					fn, method, param, body = dh.AdminMergeDish, http.MethodPost, mapParams("dishId", fmt.Sprint(dish.ID)), fmt.Sprintf(`{"target_dish_id":%d}`, target.ID)
				case "photo":
					fn, method, param, body = dh.ArchiveDishPhoto, http.MethodPost, mapParams("photoId", fmt.Sprint(photo.ID)), `{}`
				case "cover":
					fn, method, param, body = dh.SetDishPhotoCover, http.MethodPost, mapParams("photoId", fmt.Sprint(photo.ID)), `{}`
				case "online":
					fn, method, body = h.OnlineCanteen, http.MethodPost, `{}`
				case "delete":
					fn, method, body = h.DeleteCanteen, http.MethodDelete, `{}`
				}
				resp := performCanteenRequest(t, fn, method, "/archive", param, actor.ID, body)
				if role == models.RoleSuperAdmin {
					if resp.Code != http.StatusOK {
						t.Fatalf("super admin: status=%d body=%s", resp.Code, resp.Body.String())
					}
				} else {
					if resp.Code != http.StatusForbidden || !strings.Contains(resp.Body.String(), "canteen_archive_super_admin_required") {
						t.Fatalf("readonly: status=%d body=%s", resp.Code, resp.Body.String())
					}
					var stored models.Canteen
					if err := h.db.First(&stored, canteen.ID).Error; err != nil {
						t.Fatal(err)
					}
					if stored.Name != canteen.Name || stored.OperatingStatus != models.CanteenOperatingOffline {
						t.Fatalf("archive changed: %+v", stored)
					}
					var logs int64
					h.db.Model(&models.AdminLog{}).Count(&logs)
					if logs != 0 {
						t.Fatalf("denied write created %d audit logs", logs)
					}
				}
			})
		}
	}
}

func TestArchiveWriteRejectsRevokedSuperAdminDespiteStaleRole(t *testing.T) {
	h, canteen, actor := prepareReviewV2DB(t)
	h.db.Model(&canteen).Update("operating_status", models.CanteenOperatingOffline)
	h.db.Model(&actor).Update("role", models.RoleAdmin)
	resp := performCanteenRequest(t, func(c *gin.Context) {
		c.Set("role", "super_admin") // 模拟旧会话；最终权限必须以数据库为准。
		h.AdminUpdateCanteen(c)
	}, http.MethodPatch, "/archive", mapParams("id", fmt.Sprint(canteen.ID)), actor.ID, `{"name":"不能保存"}`)
	if resp.Code != http.StatusForbidden {
		t.Fatalf("revoked role: %d %s", resp.Code, resp.Body.String())
	}
}

func TestArchiveReportGovernanceRequiresSuperAdminAndRollsBackDenial(t *testing.T) {
	for _, role := range []models.Role{models.RoleAdmin, models.RoleSuperAdmin} {
		t.Run(string(role), func(t *testing.T) {
			h, canteen, actor := prepareReviewV2DB(t)
			if err := h.db.AutoMigrate(&models.Report{}, &models.CanteenSanction{}, &models.AdminActionLog{}); err != nil {
				t.Fatal(err)
			}
			if err := h.db.Model(&actor).Update("role", role).Error; err != nil {
				t.Fatal(err)
			}
			if err := h.db.Model(&canteen).Update("operating_status", models.CanteenOperatingOffline).Error; err != nil {
				t.Fatal(err)
			}
			review := models.CanteenReviewEvent{CanteenID: canteen.ID, UserID: actor.ID, OverallScore: 4, Comment: "存档评价", Status: models.ReviewEventStatusActive, ScoreVersion: 2}
			if err := h.db.Create(&review).Error; err != nil {
				t.Fatal(err)
			}
			report := models.Report{ReporterID: actor.ID, TargetType: "canteen_review", TargetID: review.ID, ReasonCode: "fabricated", Reason: "测试举报", Status: models.ReportStatusPending}
			if err := h.db.Create(&report).Error; err != nil {
				t.Fatal(err)
			}
			resp := performCanteenRequest(t, NewReportHandler(h.db).Handle, http.MethodPut, "/report", mapParams("id", fmt.Sprint(report.ID)), actor.ID, `{"status":"handled","delete_reason":"确认内容失实","confirmed_reason_code":"fabricated"}`)
			want := http.StatusForbidden
			if role == models.RoleSuperAdmin {
				want = http.StatusOK
			}
			if resp.Code != want {
				t.Fatalf("governance status=%d body=%s", resp.Code, resp.Body.String())
			}
			if err := h.db.First(&report, report.ID).Error; err != nil {
				t.Fatal(err)
			}
			if err := h.db.First(&review, review.ID).Error; err != nil {
				t.Fatal(err)
			}
			if role == models.RoleAdmin && (report.Status != models.ReportStatusPending || review.Status != models.ReviewEventStatusActive) {
				t.Fatalf("denied governance changed archive/report: %+v %+v", review, report)
			}
			if role == models.RoleSuperAdmin && (report.Status != models.ReportStatusHandled || review.Status != models.ReviewEventStatusHidden) {
				t.Fatalf("super admin governance not saved: %+v %+v", review, report)
			}
		})
	}
}
