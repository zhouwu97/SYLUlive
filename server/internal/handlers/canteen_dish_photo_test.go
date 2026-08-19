package handlers

import (
	"bytes"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/gin-gonic/gin"
	"gorm.io/driver/sqlite"
	"gorm.io/gorm"

	"shenliyuan/internal/models"
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
		&models.Canteen{},
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

func TestDishPhotoSubmissionDirectApprovalAndGalleryLimit(t *testing.T) {
	db := newDishPhotoTestDB(t)
	createVerifiedUser(t, db, 1, "管理员")
	createVerifiedUser(t, db, 2, "学生")
	canteen := models.Canteen{Name: "一食堂", Image: "/uploads/canteen.png", CreatedBy: 1, Verified: true}
	if err := db.Create(&canteen).Error; err != nil {
		t.Fatalf("create canteen: %v", err)
	}
	file := createTestFile(t, db, 10, 2, models.FileAccessPrivate)
	submit := NewCanteenDishPhotoHandler(db)

	// 1. 学生投稿第一张 → 直接 approved + File public
	resp := performDishPhotoRequest(t, submit.SubmitDishPhoto, http.MethodPost,
		fmt.Sprintf("/api/canteens/%d/dish-photos", canteen.ID),
		gin.Params{{Key: "canteenId", Value: fmt.Sprint(canteen.ID)}},
		2,
		fmt.Sprintf(`{"dish_name":"锅包肉","file_id":%d}`, file.ID))
	if resp.Code != http.StatusCreated {
		t.Fatalf("submit status=%d body=%s", resp.Code, resp.Body.String())
	}
	var photo models.CanteenDishPhoto
	if err := db.First(&photo).Error; err != nil {
		t.Fatalf("get photo: %v", err)
	}
	if photo.Status != models.DishPhotoStatusApproved {
		t.Fatalf("photo status=%s want approved", photo.Status)
	}
	// 文件应直接转为 public
	var storedFile models.File
	db.First(&storedFile, file.ID)
	if storedFile.AccessScope != models.FileAccessPublic {
		t.Fatalf("file scope=%s want public after submission", storedFile.AccessScope)
	}

	// 2. 公开列表立即直接可见
	dishHandler := NewCanteenDishHandler(db)
	listResp := performDishPhotoRequest(t, dishHandler.ListDishes, http.MethodGet,
		fmt.Sprintf("/api/canteens/%d/dishes", canteen.ID),
		gin.Params{{Key: "id", Value: fmt.Sprint(canteen.ID)}},
		0, "")
	if listResp.Code != http.StatusOK {
		t.Fatalf("list status=%d", listResp.Code)
	}
	if !strings.Contains(listResp.Body.String(), "锅包肉") {
		t.Fatalf("approved dish should be visible: %s", listResp.Body.String())
	}

	// 3. 继续上传第 2、3 张实拍 → 均直接 approved (总共 3 张)
	for i := 0; i < 2; i++ {
		f := createTestFile(t, db, uint(20+i), 2, models.FileAccessPrivate)
		r := performDishPhotoRequest(t, submit.SubmitDishPhoto, http.MethodPost,
			fmt.Sprintf("/api/canteens/%d/dish-photos", canteen.ID),
			gin.Params{{Key: "canteenId", Value: fmt.Sprint(canteen.ID)}},
			2,
			fmt.Sprintf(`{"dish_id":%d,"file_id":%d}`, photo.DishID, f.ID))
		if r.Code != http.StatusCreated {
			t.Fatalf("submit %d status=%d body=%s", i, r.Code, r.Body.String())
		}
	}

	var totalApproved int64
	db.Model(&models.CanteenDishPhoto{}).Where("dish_id = ? AND status = ?", photo.DishID, models.DishPhotoStatusApproved).Count(&totalApproved)
	if totalApproved != 3 {
		t.Fatalf("approved count=%d want 3", totalApproved)
	}

	// 4. 3/3 后再投稿第 4 张 → 409 dish_gallery_full 拦截
	f4 := createTestFile(t, db, 40, 2, models.FileAccessPrivate)
	r4 := performDishPhotoRequest(t, submit.SubmitDishPhoto, http.MethodPost,
		fmt.Sprintf("/api/canteens/%d/dish-photos", canteen.ID),
		gin.Params{{Key: "canteenId", Value: fmt.Sprint(canteen.ID)}},
		2,
		fmt.Sprintf(`{"dish_id":%d,"file_id":%d}`, photo.DishID, f4.ID))
	if r4.Code != http.StatusConflict || !strings.Contains(r4.Body.String(), "dish_gallery_full") {
		t.Fatalf("submit 4th status=%d body=%s want 409 gallery_full", r4.Code, r4.Body.String())
	}
}

func TestDishPhotoRejectKeepsPrivateAndArchiveHides(t *testing.T) {
	db := newDishPhotoTestDB(t)
	createVerifiedUser(t, db, 1, "管理员")
	createVerifiedUser(t, db, 2, "学生")
	canteen := models.Canteen{Name: "二食堂", Image: "/uploads/canteen.png", CreatedBy: 1, Verified: true}
	db.Create(&canteen)
	submit := NewCanteenDishPhotoHandler(db)
	admin := NewCanteenDishPhotoAdminHandler(db)
	dishHandler := NewCanteenDishHandler(db)

	// reject 场景（直接对已入库图片或历史 pending 图片执行驳回）
	fileR := createTestFile(t, db, 50, 2, models.FileAccessPrivate)
	dish := models.CanteenDish{CanteenID: canteen.ID, Name: "麻辣香锅", NormalizedName: "麻辣香锅", Status: models.DishStatusActive, CreatedBy: 2}
	db.Create(&dish)
	pR := models.CanteenDishPhoto{DishID: dish.ID, FileID: fileR.ID, UserID: 2, Status: models.DishPhotoStatusPending}
	db.Create(&pR)

	rejResp := performDishPhotoRequest(t, admin.RejectDishPhoto, http.MethodPost,
		fmt.Sprintf("/api/canteens/dish-photos/%d/reject", pR.ID),
		gin.Params{{Key: "photoId", Value: fmt.Sprint(pR.ID)}}, 1,
		`{"reason":"blurry"}`)
	if rejResp.Code != http.StatusOK {
		t.Fatalf("reject status=%d body=%s", rejResp.Code, rejResp.Body.String())
	}
	db.First(&pR)
	if pR.Status != models.DishPhotoStatusRejected || pR.RejectReason != "blurry" {
		t.Fatalf("photo=%+v", pR)
	}
	var fileAfterReject models.File
	db.First(&fileAfterReject, fileR.ID)
	if fileAfterReject.AccessScope != models.FileAccessPrivate {
		t.Fatalf("rejected file scope=%s want private", fileAfterReject.AccessScope)
	}

	// 非法 reason → 400
	badReason := performDishPhotoRequest(t, admin.RejectDishPhoto, http.MethodPost,
		fmt.Sprintf("/api/canteens/dish-photos/%d/reject", pR.ID),
		gin.Params{{Key: "photoId", Value: fmt.Sprint(pR.ID)}}, 1,
		`{"reason":"hate"}`)
	if badReason.Code != http.StatusBadRequest {
		t.Fatalf("bad reason status=%d", badReason.Code)
	}

	// archive 场景：上传后 archive
	fileA := createTestFile(t, db, 60, 2, models.FileAccessPrivate)
	rA := performDishPhotoRequest(t, submit.SubmitDishPhoto, http.MethodPost,
		fmt.Sprintf("/api/canteens/%d/dish-photos", canteen.ID),
		gin.Params{{Key: "canteenId", Value: fmt.Sprint(canteen.ID)}},
		2, fmt.Sprintf(`{"dish_name":"鸡腿饭","file_id":%d}`, fileA.ID))
	if rA.Code != http.StatusCreated {
		t.Fatalf("submit archive case status=%d", rA.Code)
	}
	var pA models.CanteenDishPhoto
	db.Where("file_id = ?", fileA.ID).First(&pA)
	arch := performDishPhotoRequest(t, admin.ArchiveDishPhoto, http.MethodPost,
		fmt.Sprintf("/api/canteens/dish-photos/%d/archive", pA.ID),
		gin.Params{{Key: "photoId", Value: fmt.Sprint(pA.ID)}}, 1, "")
	if arch.Code != http.StatusOK {
		t.Fatalf("archive status=%d body=%s", arch.Code, arch.Body.String())
	}
	// archived 后公共列表不可见；文件保持 public（不 revoke）
	listResp := performDishPhotoRequest(t, dishHandler.ListDishes, http.MethodGet,
		fmt.Sprintf("/api/canteens/%d/dishes", canteen.ID),
		gin.Params{{Key: "id", Value: fmt.Sprint(canteen.ID)}}, 0, "")
	if strings.Contains(listResp.Body.String(), "鸡腿饭") {
		t.Fatalf("archived dish must not be visible: %s", listResp.Body.String())
	}
	var fileAfterArchive models.File
	db.First(&fileAfterArchive, fileA.ID)
	if fileAfterArchive.AccessScope != models.FileAccessPublic {
		t.Fatalf("archived file scope=%s want public (no revoke)", fileAfterArchive.AccessScope)
	}
}

func TestDishPhotoValidationErrors(t *testing.T) {
	db := newDishPhotoTestDB(t)
	createVerifiedUser(t, db, 1, "管理员")
	createVerifiedUser(t, db, 2, "学生")
	createVerifiedUser(t, db, 3, "他人")
	canteen := models.Canteen{Name: "三食堂", Image: "/uploads/canteen.png", CreatedBy: 1, Verified: true}
	db.Create(&canteen)
	submit := NewCanteenDishPhotoHandler(db)

	// 未绑定教务 → 403
	unbound := models.User{
		ID:        4,
		StudentID: "stu-4",
		Nickname:  "未绑定",
		EduBound:  false,
	}
	db.Create(&unbound)
	fileForUnbound := createTestFile(t, db, 70, 4, models.FileAccessPrivate)
	resp := performDishPhotoRequest(t, submit.SubmitDishPhoto, http.MethodPost,
		fmt.Sprintf("/api/canteens/%d/dish-photos", canteen.ID),
		gin.Params{{Key: "canteenId", Value: fmt.Sprint(canteen.ID)}},
		4, fmt.Sprintf(`{"dish_name":"蛋炒饭","file_id":%d}`, fileForUnbound.ID))
	if resp.Code != http.StatusForbidden || !strings.Contains(resp.Body.String(), "edu_binding_required") {
		t.Fatalf("unbound status=%d body=%s", resp.Code, resp.Body.String())
	}

	// 空菜名 → 400
	fileE := createTestFile(t, db, 71, 2, models.FileAccessPrivate)
	resp = performDishPhotoRequest(t, submit.SubmitDishPhoto, http.MethodPost,
		fmt.Sprintf("/api/canteens/%d/dish-photos", canteen.ID),
		gin.Params{{Key: "canteenId", Value: fmt.Sprint(canteen.ID)}},
		2, fmt.Sprintf(`{"dish_name":"  ","file_id":%d}`, fileE.ID))
	if resp.Code != http.StatusBadRequest {
		t.Fatalf("empty dish name status=%d body=%s", resp.Code, resp.Body.String())
	}

	// 菜名超过 40 个可见字符 → 400（而非数据库 size:100 错误）
	longName := strings.Repeat("长", MaxDishNameLength+1)
	fileLong := createTestFile(t, db, 75, 2, models.FileAccessPrivate)
	resp = performDishPhotoRequest(t, submit.SubmitDishPhoto, http.MethodPost,
		fmt.Sprintf("/api/canteens/%d/dish-photos", canteen.ID),
		gin.Params{{Key: "canteenId", Value: fmt.Sprint(canteen.ID)}},
		2, fmt.Sprintf(`{"dish_name":%q,"file_id":%d}`, longName, fileLong.ID))
	if resp.Code != http.StatusBadRequest {
		t.Fatalf("long dish name status=%d body=%s", resp.Code, resp.Body.String())
	}

	// 恰好 40 个字符 → 40 字应成功
	boundaryName := strings.Repeat("短", MaxDishNameLength)
	fileOk := createTestFile(t, db, 76, 2, models.FileAccessPrivate)
	resp = performDishPhotoRequest(t, submit.SubmitDishPhoto, http.MethodPost,
		fmt.Sprintf("/api/canteens/%d/dish-photos", canteen.ID),
		gin.Params{{Key: "canteenId", Value: fmt.Sprint(canteen.ID)}},
		2, fmt.Sprintf(`{"dish_name":%q,"file_id":%d}`, boundaryName, fileOk.ID))
	if resp.Code != http.StatusCreated {
		t.Fatalf("40-char dish name status=%d body=%s", resp.Code, resp.Body.String())
	}

	// 引用他人 private File → 400（owner 校验）
	fileOther := createTestFile(t, db, 72, 3, models.FileAccessPrivate)
	resp = performDishPhotoRequest(t, submit.SubmitDishPhoto, http.MethodPost,
		fmt.Sprintf("/api/canteens/%d/dish-photos", canteen.ID),
		gin.Params{{Key: "canteenId", Value: fmt.Sprint(canteen.ID)}},
		2, fmt.Sprintf(`{"dish_name":"蛋炒饭","file_id":%d}`, fileOther.ID))
	if resp.Code != http.StatusBadRequest {
		t.Fatalf("other private file status=%d body=%s", resp.Code, resp.Body.String())
	}

	// 非图片 File → 400
	uploadDir := os.Getenv("UPLOAD_DIR")
	if uploadDir != "" {
		_ = os.WriteFile(filepath.Join(uploadDir, "doc.pdf"), []byte("pdf"), 0o600)
	}
	nonImage := models.File{
		ID: 73, Hash: "h73", Path: "/uploads/doc.pdf", Size: 10,
		MimeType: "application/pdf", UploaderID: 2, Status: "temporary", AccessScope: models.FileAccessPrivate,
	}
	db.Create(&nonImage)
	resp = performDishPhotoRequest(t, submit.SubmitDishPhoto, http.MethodPost,
		fmt.Sprintf("/api/canteens/%d/dish-photos", canteen.ID),
		gin.Params{{Key: "canteenId", Value: fmt.Sprint(canteen.ID)}},
		2, `{"dish_name":"蛋炒饭","file_id":73}`)
	if resp.Code != http.StatusBadRequest {
		t.Fatalf("non-image file status=%d body=%s", resp.Code, resp.Body.String())
	}

	// 未验证食堂 → 404
	unverified := models.Canteen{Name: "未审核食堂", Image: "/uploads/x.png", CreatedBy: 2, Verified: false}
	db.Create(&unverified)
	fileU := createTestFile(t, db, 74, 2, models.FileAccessPrivate)
	resp = performDishPhotoRequest(t, submit.SubmitDishPhoto, http.MethodPost,
		fmt.Sprintf("/api/canteens/%d/dish-photos", unverified.ID),
		gin.Params{{Key: "canteenId", Value: fmt.Sprint(unverified.ID)}},
		2, fmt.Sprintf(`{"dish_name":"蛋炒饭","file_id":%d}`, fileU.ID))
	if resp.Code != http.StatusNotFound {
		t.Fatalf("unverified canteen status=%d body=%s", resp.Code, resp.Body.String())
	}
}

func TestDishPhotoNormalizedNameReuse(t *testing.T) {
	db := newDishPhotoTestDB(t)
	createVerifiedUser(t, db, 1, "管理员")
	createVerifiedUser(t, db, 2, "学生二")
	createVerifiedUser(t, db, 3, "学生三")
	canteen := models.Canteen{Name: "四食堂", Image: "/uploads/canteen.png", CreatedBy: 1, Verified: true}
	db.Create(&canteen)
	submit := NewCanteenDishPhotoHandler(db)

	f1 := createTestFile(t, db, 80, 2, models.FileAccessPrivate)
	r1 := performDishPhotoRequest(t, submit.SubmitDishPhoto, http.MethodPost,
		fmt.Sprintf("/api/canteens/%d/dish-photos", canteen.ID),
		gin.Params{{Key: "canteenId", Value: fmt.Sprint(canteen.ID)}},
		2, fmt.Sprintf(`{"dish_name":" 锅 包 肉 ","file_id":%d}`, f1.ID))
	if r1.Code != http.StatusCreated {
		t.Fatalf("first submit status=%d body=%s", r1.Code, r1.Body.String())
	}

	f2 := createTestFile(t, db, 81, 3, models.FileAccessPrivate)
	r2 := performDishPhotoRequest(t, submit.SubmitDishPhoto, http.MethodPost,
		fmt.Sprintf("/api/canteens/%d/dish-photos", canteen.ID),
		gin.Params{{Key: "canteenId", Value: fmt.Sprint(canteen.ID)}},
		3, fmt.Sprintf(`{"dish_name":"锅包肉","file_id":%d}`, f2.ID))
	if r2.Code != http.StatusCreated {
		t.Fatalf("second submit status=%d body=%s", r2.Code, r2.Body.String())
	}

	var dishCount int64
	db.Model(&models.CanteenDish{}).Where("canteen_id = ? AND normalized_name = ?", canteen.ID, "锅包肉").Count(&dishCount)
	if dishCount != 1 {
		t.Fatalf("normalized dish count=%d want 1 (reuse)", dishCount)
	}

	var approvedCount int64
	db.Model(&models.CanteenDishPhoto{}).Where("status = ?", models.DishPhotoStatusApproved).Count(&approvedCount)
	if approvedCount != 2 {
		t.Fatalf("approved count=%d want 2", approvedCount)
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
