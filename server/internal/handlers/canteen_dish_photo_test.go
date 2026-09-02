package handlers

import (
	"bytes"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/glebarez/sqlite"
	"gorm.io/gorm"

	"shenliyuan/internal/models"
	"shenliyuan/internal/services"
)

func newDishPhotoTestDB(t *testing.T) *gorm.DB {
	t.Helper()
	uploadDir := t.TempDir()
	t.Setenv("UPLOAD_DIR", uploadDir)

	db, err := gorm.Open(sqlite.Open(":memory:"), &gorm.Config{})
	if err != nil {
		t.Fatalf("open sqlite: %v", err)
	}
	if err := db.AutoMigrate(
		&models.User{},
		&models.File{},
		&models.FileUploadGrant{},
		&models.ImageVariant{},
		&models.Canteen{},
		&models.CanteenRating{},
		&models.CanteenRatingVote{},
		&models.CanteenReviewEvent{},
		&models.CanteenDish{},
		&models.CanteenDishPhoto{},
		&models.AdminLog{},
	); err != nil {
		t.Fatalf("migrate: %v", err)
	}
	if err := models.EnsureCanteenDishSchema(db); err != nil {
		t.Fatalf("ensure schema: %v", err)
	}
	return db
}

func TestListDishesOmitsReviewImageGallery(t *testing.T) {
	db := newDishPhotoTestDB(t)
	canteen := models.Canteen{Name: "评价图片食堂", Image: "/uploads/canteen.png", CreatedBy: 1, Verified: true}
	if err := db.Create(&canteen).Error; err != nil {
		t.Fatal(err)
	}
	now := time.Now().UTC()
	if err := db.Create(&models.CanteenReviewEvent{
		CanteenID: canteen.ID, UserID: 1, Status: models.ReviewEventStatusActive,
		Images: `[{"not":"a string"}]`, CreatedAt: now.Add(-2 * time.Hour),
	}).Error; err != nil {
		t.Fatal(err)
	}
	if err := db.Create(&models.CanteenReviewEvent{
		CanteenID: canteen.ID, UserID: 3, Status: models.ReviewEventStatusActive,
		Images: `["/uploads/review-new.jpg","/uploads/review-duplicate.jpg"]`, CreatedAt: now,
	}).Error; err != nil {
		t.Fatal(err)
	}
	if err := db.Create(&models.CanteenReviewEvent{
		CanteenID: canteen.ID, UserID: 4, Status: models.ReviewEventStatusHidden,
		Images: `["/uploads/hidden.jpg"]`, CreatedAt: now.Add(time.Hour),
	}).Error; err != nil {
		t.Fatal(err)
	}
	if err := db.Create(&models.CanteenRating{
		CanteenID: canteen.ID, UserID: 5, Star: 5, Status: models.ReviewEventStatusActive,
		Images: `["/uploads/review-duplicate.jpg","/uploads/legacy.jpg"]`, CreatedAt: now.Add(-30 * time.Minute),
	}).Error; err != nil {
		t.Fatal(err)
	}

	resp := performDishPhotoRequest(t, NewCanteenDishHandler(db).ListDishes, http.MethodGet,
		fmt.Sprintf("/api/canteens/%d/dishes", canteen.ID),
		gin.Params{{Key: "id", Value: fmt.Sprint(canteen.ID)}}, 0, "")
	if resp.Code != http.StatusOK {
		t.Fatalf("list status=%d body=%s", resp.Code, resp.Body.String())
	}
	var rows []map[string]interface{}
	if err := json.Unmarshal(resp.Body.Bytes(), &rows); err != nil {
		t.Fatalf("decode list: %v", err)
	}
	if len(rows) != 0 {
		t.Fatalf("review image gallery must not be returned as a dish: %#v", rows)
	}
	if strings.Contains(resp.Body.String(), "用户评价实拍") ||
		strings.Contains(resp.Body.String(), "review_images") ||
		strings.Contains(resp.Body.String(), "/uploads/review-new.jpg") ||
		strings.Contains(resp.Body.String(), "hidden.jpg") {
		t.Fatalf("review images must not leak into dish list: %s", resp.Body.String())
	}
}

func createVerifiedUser(t *testing.T, db *gorm.DB, id uint, nickname string) models.User {
	t.Helper()
	now := time.Now()
	u := models.User{
		ID:                id,
		StudentID:         fmt.Sprintf("stu-%d", id),
		Nickname:          nickname,
		StudentVerifiedAt: &now,
		EduBound:          true,
	}
	if err := db.Create(&u).Error; err != nil {
		t.Fatalf("create user: %v", err)
	}
	return u
}

func createTestFile(t *testing.T, db *gorm.DB, id, uploaderID uint, scope models.FileAccessScope) models.File {
	t.Helper()
	filename := fmt.Sprintf("photo-%d.jpg", id)
	uploadDir := os.Getenv("UPLOAD_DIR")
	if uploadDir != "" {
		_ = os.WriteFile(filepath.Join(uploadDir, filename), []byte("dummy image content"), 0o600)
	}
	f := models.File{
		ID:          id,
		Hash:        fmt.Sprintf("hash-%d", id),
		Path:        fmt.Sprintf("/uploads/%s", filename),
		Size:        1024,
		MimeType:    "image/jpeg",
		UploaderID:  uploaderID,
		Status:      "temporary",
		AccessScope: scope,
	}
	if err := db.Create(&f).Error; err != nil {
		t.Fatalf("create file: %v", err)
	}
	return f
}

func performDishPhotoRequest(
	t *testing.T,
	handler gin.HandlerFunc,
	method, path string,
	params gin.Params,
	userID uint,
	body string,
) *httptest.ResponseRecorder {
	t.Helper()
	gin.SetMode(gin.TestMode)
	recorder := httptest.NewRecorder()
	context, _ := gin.CreateTestContext(recorder)
	var req *http.Request
	if body != "" {
		req = httptest.NewRequest(method, path, bytes.NewBufferString(body))
		req.Header.Set("Content-Type", "application/json")
	} else {
		req = httptest.NewRequest(method, path, nil)
	}
	context.Request = req
	context.Params = params
	if userID > 0 {
		context.Set("user_id", userID)
	}
	handler(context)
	return recorder
}

func TestRetiredDishSubmissionEndpointsReturnMigrationContract(t *testing.T) {
	db := newDishPhotoTestDB(t)
	photoHandler := NewCanteenDishPhotoHandler(db)
	for _, tc := range []struct {
		name    string
		handler gin.HandlerFunc
		path    string
		params  gin.Params
	}{
		{
			name:    "legacy dish photos",
			handler: photoHandler.SubmitDishPhoto,
			path:    "/api/canteens/1/dish-photos",
			params:  gin.Params{{Key: "canteenId", Value: "1"}},
		},
		{
			name:    "v2 dish submissions",
			handler: photoHandler.SubmitDishPhotoV2,
			path:    "/api/canteens/1/dish-submissions",
			params:  gin.Params{{Key: "id", Value: "1"}},
		},
		{
			name:    "dish resubmit",
			handler: NewCanteenHandler(db).ResubmitDish,
			path:    "/api/canteens/dishes/1/resubmit",
			params:  gin.Params{{Key: "dishId", Value: "1"}},
		},
	} {
		t.Run(tc.name, func(t *testing.T) {
			response := performDishPhotoRequest(t, tc.handler, http.MethodPost,
				tc.path, tc.params, 1, `{"dish_name":"锅包肉","file_id":1}`)
			if response.Code != http.StatusGone ||
				!strings.Contains(response.Body.String(), `"code":"dish_submission_retired"`) {
				t.Fatalf("status=%d body=%s", response.Code, response.Body.String())
			}
		})
	}
}

func TestDishPhotoArchiveHidesAndReconciles(t *testing.T) {
	db := newDishPhotoTestDB(t)
	createVerifiedUser(t, db, 1, "管理员")
	createVerifiedUser(t, db, 2, "学生")
	canteen := models.Canteen{Name: "二食堂", Image: "/uploads/canteen.png", CreatedBy: 1, Verified: true}
	db.Create(&canteen)
	admin := NewCanteenDishPhotoAdminHandler(db)
	dishHandler := NewCanteenDishHandler(db)

	// archive 场景：实拍下架
	fileA := createTestFile(t, db, 60, 2, models.FileAccessPublic)
	dishA := models.CanteenDish{
		CanteenID: canteen.ID, Name: "鸡腿饭", NormalizedName: "鸡腿饭",
		Status: models.DishStatusActive, CreatedBy: 2,
	}
	if err := db.Create(&dishA).Error; err != nil {
		t.Fatal(err)
	}
	pA := models.CanteenDishPhoto{
		DishID: dishA.ID, FileID: fileA.ID, UserID: 2,
		Status: models.DishPhotoStatusApproved,
	}
	if err := db.Create(&pA).Error; err != nil {
		t.Fatal(err)
	}

	arch := performDishPhotoRequest(t, admin.ArchiveDishPhoto, http.MethodPost,
		fmt.Sprintf("/api/canteens/dish-photos/%d/archive", pA.ID),
		gin.Params{{Key: "photoId", Value: fmt.Sprint(pA.ID)}}, 1, "")
	if arch.Code != http.StatusOK {
		t.Fatalf("archive status=%d body=%s", arch.Code, arch.Body.String())
	}
	// archived 后实拍不可见，但 active 菜品本身仍保留在公共菜品库；
	// 孤立文件无其他公开引用应被回收为 private。
	listResp := performDishPhotoRequest(t, dishHandler.ListDishes, http.MethodGet,
		fmt.Sprintf("/api/canteens/%d/dishes", canteen.ID),
		gin.Params{{Key: "id", Value: fmt.Sprint(canteen.ID)}}, 0, "")
	if !strings.Contains(listResp.Body.String(), "鸡腿饭") ||
		!strings.Contains(listResp.Body.String(), `"photo_count":0`) {
		t.Fatalf("active dish should remain visible without approved photo: %s", listResp.Body.String())
	}
	var fileAfterArchive models.File
	db.First(&fileAfterArchive, fileA.ID)
	if fileAfterArchive.AccessScope != models.FileAccessPrivate {
		t.Fatalf("archived orphan file scope=%s want private after reconcile", fileAfterArchive.AccessScope)
	}
}

func TestRetiredDishPhotoEndpointContract(t *testing.T) {
	response := performDishPhotoRequest(t, NewCanteenDishPhotoHandler(newDishPhotoTestDB(t)).SubmitDishPhoto,
		http.MethodPost, "/api/canteens/1/dish-photos",
		gin.Params{{Key: "canteenId", Value: "1"}}, 1,
		`{"dish_name":"锅包肉","file_id":1}`)
	if response.Code != http.StatusGone || !strings.Contains(response.Body.String(), "dish_submission_retired") {
		t.Fatalf("retired submission status=%d body=%s", response.Code, response.Body.String())
	}
}

func TestMigratePendingCanteenDishPhotos(t *testing.T) {
	db := newDishPhotoTestDB(t)
	createVerifiedUser(t, db, 1, "管理员")
	createVerifiedUser(t, db, 2, "学生")
	canteen := models.Canteen{Name: "六食堂", Image: "/uploads/canteen.png", CreatedBy: 1, Verified: true}
	db.Create(&canteen)
	dish := models.CanteenDish{CanteenID: canteen.ID, Name: "水煮鱼", NormalizedName: "水煮鱼", Status: models.DishStatusActive, CreatedBy: 2}
	db.Create(&dish)

	// 已有 1 个 approved
	f1 := createTestFile(t, db, 90, 2, models.FileAccessPrivate)
	db.Create(&models.CanteenDishPhoto{DishID: dish.ID, FileID: f1.ID, UserID: 2, Status: models.DishPhotoStatusApproved, CreatedAt: time.Now().Add(-10 * time.Minute)})
	db.Model(&f1).Updates(map[string]interface{}{"status": "active", "access_scope": models.FileAccessPublic})

	// 注入 3 个 pending（历史数据，分别来自不同用户）
	createVerifiedUser(t, db, 3, "学生三")
	createVerifiedUser(t, db, 4, "学生四")

	f2 := createTestFile(t, db, 91, 2, models.FileAccessPrivate)
	p2 := models.CanteenDishPhoto{DishID: dish.ID, FileID: f2.ID, UserID: 2, Status: models.DishPhotoStatusPending, CreatedAt: time.Now().Add(-5 * time.Minute)}
	db.Create(&p2)

	f3 := createTestFile(t, db, 92, 3, models.FileAccessPrivate)
	p3 := models.CanteenDishPhoto{DishID: dish.ID, FileID: f3.ID, UserID: 3, Status: models.DishPhotoStatusPending, CreatedAt: time.Now().Add(-4 * time.Minute)}
	db.Create(&p3)

	f4 := createTestFile(t, db, 93, 4, models.FileAccessPrivate)
	p4 := models.CanteenDishPhoto{DishID: dish.ID, FileID: f4.ID, UserID: 4, Status: models.DishPhotoStatusPending, CreatedAt: time.Now().Add(-1 * time.Minute)}
	db.Create(&p4)

	// 执行迁移
	if err := models.MigratePendingCanteenDishPhotos(db); err != nil {
		t.Fatalf("migrate pending photos error: %v", err)
	}

	var approvedCount int64
	db.Model(&models.CanteenDishPhoto{}).Where("dish_id = ? AND status = ?", dish.ID, models.DishPhotoStatusApproved).Count(&approvedCount)
	if approvedCount != 3 {
		t.Fatalf("approved count=%d want exactly 3 after migration", approvedCount)
	}

	var archivedCount int64
	db.Model(&models.CanteenDishPhoto{}).Where("dish_id = ? AND status = ?", dish.ID, models.DishPhotoStatusArchived).Count(&archivedCount)
	if archivedCount != 1 {
		t.Fatalf("archived count=%d want 1 for photo exceeding capacity", archivedCount)
	}

	// 检查升级为 approved 的文件是否变为 public
	var file2, file3, file4 models.File
	db.First(&file2, f2.ID)
	db.First(&file3, f3.ID)
	db.First(&file4, f4.ID)

	if file2.AccessScope != models.FileAccessPublic {
		t.Fatalf("file2 scope=%s want public", file2.AccessScope)
	}
	if file3.AccessScope != models.FileAccessPublic {
		t.Fatalf("file3 scope=%s want public", file3.AccessScope)
	}
	// 第 4 个被归档，文件保持 private
	if file4.AccessScope != models.FileAccessPrivate {
		t.Fatalf("file4 scope=%s want private", file4.AccessScope)
	}
}

func TestMigratePendingCanteenDishPhotosSkipsMissingFiles(t *testing.T) {
	db := newDishPhotoTestDB(t)
	createVerifiedUser(t, db, 1, "管理员")
	createVerifiedUser(t, db, 2, "学生A")
	createVerifiedUser(t, db, 3, "学生B")

	canteen := models.Canteen{Name: "七食堂", Image: "/uploads/canteen.png", CreatedBy: 1, Verified: true}
	db.Create(&canteen)
	dish := models.CanteenDish{CanteenID: canteen.ID, Name: "酸菜鱼", NormalizedName: "酸菜鱼", Status: models.DishStatusActive, CreatedBy: 2}
	db.Create(&dish)

	// Pending 1: File 记录存在但磁盘文件被删除
	fCorrupt := createTestFile(t, db, 110, 2, models.FileAccessPrivate)
	diskPath := filepath.Join(os.Getenv("UPLOAD_DIR"), "photo-110.jpg")
	_ = os.Remove(diskPath) // 模拟磁盘文件丢失

	pCorrupt := models.CanteenDishPhoto{DishID: dish.ID, FileID: fCorrupt.ID, UserID: 2, Status: models.DishPhotoStatusPending, CreatedAt: time.Now().Add(-10 * time.Minute)}
	db.Create(&pCorrupt)

	// Pending 2: 真实有效文件
	fValid := createTestFile(t, db, 111, 3, models.FileAccessPrivate)
	pValid := models.CanteenDishPhoto{DishID: dish.ID, FileID: fValid.ID, UserID: 3, Status: models.DishPhotoStatusPending, CreatedAt: time.Now().Add(-5 * time.Minute)}
	db.Create(&pValid)

	if err := models.MigratePendingCanteenDishPhotos(db); err != nil {
		t.Fatalf("migrate: %v", err)
	}

	var photo1, photo2 models.CanteenDishPhoto
	db.First(&photo1, pCorrupt.ID)
	db.First(&photo2, pValid.ID)

	if photo1.Status != models.DishPhotoStatusArchived {
		t.Fatalf("corrupt photo status=%s want archived", photo1.Status)
	}
	if photo2.Status != models.DishPhotoStatusApproved {
		t.Fatalf("valid photo status=%s want approved", photo2.Status)
	}
}

func TestAdminDishUpdateRenameAndHide(t *testing.T) {
	db := newDishPhotoTestDB(t)
	createVerifiedUser(t, db, 1, "管理员")
	canteen := models.Canteen{Name: "五食堂", Image: "/uploads/canteen.png", CreatedBy: 1, Verified: true}
	db.Create(&canteen)
	dish := models.CanteenDish{CanteenID: canteen.ID, Name: "红烧肉", NormalizedName: "红烧肉", Status: models.DishStatusActive, CreatedBy: 1}
	db.Create(&dish)
	admin := NewCanteenDishPhotoAdminHandler(db)

	// 重命名
	renameResp := performDishPhotoRequest(t, admin.AdminUpdateDish, http.MethodPatch,
		fmt.Sprintf("/api/canteens/dishes/%d", dish.ID),
		gin.Params{{Key: "dishId", Value: fmt.Sprint(dish.ID)}}, 1,
		`{"name":"秘制红烧肉"}`)
	if renameResp.Code != http.StatusOK {
		t.Fatalf("rename status=%d body=%s", renameResp.Code, renameResp.Body.String())
	}
	var refreshed models.CanteenDish
	db.First(&refreshed, dish.ID)
	if refreshed.Name != "秘制红烧肉" || refreshed.NormalizedName != "秘制红烧肉" {
		t.Fatalf("renamed dish=%+v", refreshed)
	}

	// 隐藏
	hideResp := performDishPhotoRequest(t, admin.AdminUpdateDish, http.MethodPatch,
		fmt.Sprintf("/api/canteens/dishes/%d", dish.ID),
		gin.Params{{Key: "dishId", Value: fmt.Sprint(dish.ID)}}, 1,
		`{"status":"hidden"}`)
	if hideResp.Code != http.StatusOK {
		t.Fatalf("hide status=%d", hideResp.Code)
	}
	db.First(&refreshed, dish.ID)
	if refreshed.Status != models.DishStatusHidden {
		t.Fatalf("hidden dish=%+v", refreshed)
	}

	// 非法 status → 400
	badStatus := performDishPhotoRequest(t, admin.AdminUpdateDish, http.MethodPatch,
		fmt.Sprintf("/api/canteens/dishes/%d", dish.ID),
		gin.Params{{Key: "dishId", Value: fmt.Sprint(dish.ID)}}, 1,
		`{"status":"deleted"}`)
	if badStatus.Code != http.StatusBadRequest {
		t.Fatalf("bad status=%d", badStatus.Code)
	}

	// 重名 → 409
	dish2 := models.CanteenDish{CanteenID: canteen.ID, Name: "红烧狮子头", NormalizedName: "红烧狮子头", Status: models.DishStatusActive, CreatedBy: 1}
	db.Create(&dish2)
	conflict := performDishPhotoRequest(t, admin.AdminUpdateDish, http.MethodPatch,
		fmt.Sprintf("/api/canteens/dishes/%d", dish2.ID),
		gin.Params{{Key: "dishId", Value: fmt.Sprint(dish2.ID)}}, 1,
		`{"name":"秘制红烧肉"}`)
	if conflict.Code != http.StatusConflict {
		t.Fatalf("name conflict status=%d body=%s", conflict.Code, conflict.Body.String())
	}

	// 空名 → 400
	empty := performDishPhotoRequest(t, admin.AdminUpdateDish, http.MethodPatch,
		fmt.Sprintf("/api/canteens/dishes/%d", dish.ID),
		gin.Params{{Key: "dishId", Value: fmt.Sprint(dish.ID)}}, 1,
		`{"name":"  "}`)
	if empty.Code != http.StatusBadRequest {
		t.Fatalf("empty name status=%d", empty.Code)
	}
}

func TestAdminArchiveDishPhotoReconcilesFilePublicAccess(t *testing.T) {
	db := newDishPhotoTestDB(t)
	createVerifiedUser(t, db, 1, "管理员")
	createVerifiedUser(t, db, 2, "学生A")

	canteen := models.Canteen{Name: "八食堂", Image: "/uploads/canteen.png", CreatedBy: 1, Verified: true}
	db.Create(&canteen)
	dish := models.CanteenDish{CanteenID: canteen.ID, Name: "水饺", NormalizedName: "水饺", Status: models.DishStatusActive, CreatedBy: 2}
	db.Create(&dish)

	// 上传实拍 1（文件 201）
	f1 := createTestFile(t, db, 201, 2, models.FileAccessPrivate)
	p1 := models.CanteenDishPhoto{DishID: dish.ID, FileID: f1.ID, UserID: 2, Status: models.DishPhotoStatusApproved}
	db.Create(&p1)
	services.ClaimPublicImageFiles(db, []uint{f1.ID})

	var fileBefore models.File
	db.First(&fileBefore, f1.ID)
	if fileBefore.AccessScope != models.FileAccessPublic {
		t.Fatalf("fileBefore scope=%s want public", fileBefore.AccessScope)
	}

	admin := NewCanteenDishPhotoAdminHandler(db)
	archiveResp := performDishPhotoRequest(t, admin.ArchiveDishPhoto, http.MethodPost,
		fmt.Sprintf("/api/canteens/dish-photos/%d/archive", p1.ID),
		gin.Params{{Key: "photoId", Value: fmt.Sprint(p1.ID)}}, 1, "")
	if archiveResp.Code != http.StatusOK {
		t.Fatalf("archive status=%d body=%s", archiveResp.Code, archiveResp.Body.String())
	}

	// 孤儿文件无其他公开引用，应被降级为 private
	var fileAfter models.File
	db.First(&fileAfter, f1.ID)
	if fileAfter.AccessScope != models.FileAccessPrivate {
		t.Fatalf("fileAfter scope=%s want private after reconcile", fileAfter.AccessScope)
	}
}

func TestAdminGetDishPhotoDetail(t *testing.T) {
	db := newDishPhotoTestDB(t)
	createVerifiedUser(t, db, 1, "管理员")
	createVerifiedUser(t, db, 2, "张三同学")

	canteen := models.Canteen{Name: "九食堂", Image: "/uploads/canteen.png", CreatedBy: 1, Verified: true}
	db.Create(&canteen)
	dish := models.CanteenDish{CanteenID: canteen.ID, Name: "排骨饭", NormalizedName: "排骨饭", Status: models.DishStatusActive, CreatedBy: 2}
	db.Create(&dish)

	f1 := createTestFile(t, db, 202, 2, models.FileAccessPublic)
	p1 := models.CanteenDishPhoto{DishID: dish.ID, FileID: f1.ID, UserID: 2, Status: models.DishPhotoStatusApproved}
	db.Create(&p1)

	admin := NewCanteenDishPhotoAdminHandler(db)
	resp := performDishPhotoRequest(t, admin.AdminGetDishPhotoDetail, http.MethodGet,
		fmt.Sprintf("/api/canteens/dish-photos/%d", p1.ID),
		gin.Params{{Key: "photoId", Value: fmt.Sprint(p1.ID)}}, 1, "")
	if resp.Code != http.StatusOK {
		t.Fatalf("detail status=%d body=%s", resp.Code, resp.Body.String())
	}

	var data map[string]interface{}
	if err := json.Unmarshal(resp.Body.Bytes(), &data); err != nil {
		t.Fatalf("json parse: %v", err)
	}
	if data["uploader_name"] != "张三同学" {
		t.Fatalf("uploader_name=%v want 张三同学", data["uploader_name"])
	}
	if fmt.Sprint(data["uploader_id"]) != "2" {
		t.Fatalf("uploader_id=%v want 2", data["uploader_id"])
	}
}

