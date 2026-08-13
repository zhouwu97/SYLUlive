package handlers

import (
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
	"gorm.io/gorm"

	"shenliyuan/internal/models"
	"shenliyuan/internal/services"
)

// newDishPhotoTestDB 扩展食堂测试库：追加菜品图库模型与约束。
// UPLOAD_DIR 指向临时目录，避免测试生成的假图片污染源码树 uploads/。
func newDishPhotoTestDB(t *testing.T) *gorm.DB {
	t.Helper()
	t.Setenv("UPLOAD_DIR", t.TempDir())
	db := newCanteenTestDB(t)
	if err := db.AutoMigrate(&models.CanteenDish{}, &models.CanteenDishPhoto{}); err != nil {
		t.Fatalf("migrate dish models: %v", err)
	}
	if err := models.EnsureCanteenDishSchema(db); err != nil {
		t.Fatalf("ensure dish schema: %v", err)
	}
	return db
}

func createVerifiedUser(t *testing.T, db *gorm.DB, id uint, nickname string) models.User {
	t.Helper()
	user := createCanteenTestUser(t, db, id, nickname)
	if err := db.Model(&models.User{}).Where("id = ?", id).Updates(map[string]interface{}{
		"student_verified_at": time.Now(),
		"edu_authorized":      true,
		"edu_bound":           true,
	}).Error; err != nil {
		t.Fatalf("verify user: %v", err)
	}
	return user
}

func createTestFile(t *testing.T, db *gorm.DB, id uint, uploader uint, scope models.FileAccessScope) models.File {
	t.Helper()
	path := fmt.Sprintf("/uploads/dish-%d.jpg", id)
	// ValidateImageFileIDs 会 os.Stat 磁盘文件：写入真实占位文件。
	diskPath, err := services.ResolveUploadPath("", path)
	if err != nil {
		t.Fatalf("resolve upload path: %v", err)
	}
	if err := os.MkdirAll(filepath.Dir(diskPath), 0o755); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	if err := os.WriteFile(diskPath, []byte("fake-image"), 0o644); err != nil {
		t.Fatalf("write file: %v", err)
	}
	file := models.File{
		ID:          id,
		Hash:        fmt.Sprintf("hash-%d", id),
		Path:        path,
		Size:        1024,
		MimeType:    "image/jpeg",
		UploaderID:  uploader,
		Status:      "temporary",
		AccessScope: scope,
	}
	if err := db.Create(&file).Error; err != nil {
		t.Fatalf("create file: %v", err)
	}
	return file
}

// performDishPhotoRequest 执行投稿/审核请求。
func performDishPhotoRequest(
	t *testing.T,
	handler gin.HandlerFunc,
	method string,
	path string,
	params gin.Params,
	userID uint,
	body string,
) *httptest.ResponseRecorder {
	t.Helper()
	gin.SetMode(gin.TestMode)
	recorder := httptest.NewRecorder()
	context, _ := gin.CreateTestContext(recorder)
	context.Request = httptest.NewRequest(method, path, strings.NewReader(body))
	context.Request.Header.Set("Content-Type", "application/json")
	context.Params = params
	if userID != 0 {
		context.Set("user_id", userID)
	}
	handler(context)
	return recorder
}

func TestDishPhotoSubmissionAndApprovalLifecycle(t *testing.T) {
	db := newDishPhotoTestDB(t)
	createVerifiedUser(t, db, 1, "管理员")
	createVerifiedUser(t, db, 2, "学生")
	canteen := models.Canteen{Name: "一食堂", Image: "/uploads/canteen.png", CreatedBy: 1, Verified: true}
	if err := db.Create(&canteen).Error; err != nil {
		t.Fatalf("create canteen: %v", err)
	}
	file := createTestFile(t, db, 10, 2, models.FileAccessPrivate)
	submit := NewCanteenDishPhotoHandler(db)
	admin := NewCanteenDishPhotoAdminHandler(db)

	// 1. 学生投稿第一张 → pending
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
	if photo.Status != models.DishPhotoStatusPending {
		t.Fatalf("photo status=%s want pending", photo.Status)
	}
	// 文件应保持 private（ClaimPrivateFiles 只激活，不公开）
	var storedFile models.File
	db.First(&storedFile, file.ID)
	if storedFile.AccessScope != models.FileAccessPrivate {
		t.Fatalf("file scope=%s want private before approval", storedFile.AccessScope)
	}

	// 2. pending 图片公共接口不可见
	dishHandler := NewCanteenDishHandler(db)
	listResp := performDishPhotoRequest(t, dishHandler.ListDishes, http.MethodGet,
		fmt.Sprintf("/api/canteens/%d/dishes", canteen.ID),
		gin.Params{{Key: "id", Value: fmt.Sprint(canteen.ID)}},
		0, "")
	if listResp.Code != http.StatusOK {
		t.Fatalf("list status=%d", listResp.Code)
	}
	if strings.Contains(listResp.Body.String(), "锅包肉") {
		t.Fatalf("pending dish must not be visible: %s", listResp.Body.String())
	}

	// 3. 管理员 approve → approved + File public
	approveResp := performDishPhotoRequest(t, admin.ApproveDishPhoto, http.MethodPost,
		fmt.Sprintf("/api/canteens/dish-photos/%d/approve", photo.ID),
		gin.Params{{Key: "photoId", Value: fmt.Sprint(photo.ID)}},
		1, "")
	if approveResp.Code != http.StatusOK {
		t.Fatalf("approve status=%d body=%s", approveResp.Code, approveResp.Body.String())
	}
	db.First(&storedFile, file.ID)
	if storedFile.AccessScope != models.FileAccessPublic {
		t.Fatalf("file scope=%s want public after approval", storedFile.AccessScope)
	}

	// 4. 公开列表现在可见
	listResp = performDishPhotoRequest(t, dishHandler.ListDishes, http.MethodGet,
		fmt.Sprintf("/api/canteens/%d/dishes", canteen.ID),
		gin.Params{{Key: "id", Value: fmt.Sprint(canteen.ID)}},
		0, "")
	if !strings.Contains(listResp.Body.String(), "锅包肉") {
		t.Fatalf("approved dish should be visible: %s", listResp.Body.String())
	}

	// 5. 2/3 → 3/3
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
		var p models.CanteenDishPhoto
		db.Where("file_id = ?", f.ID).First(&p)
		ar := performDishPhotoRequest(t, admin.ApproveDishPhoto, http.MethodPost,
			fmt.Sprintf("/api/canteens/dish-photos/%d/approve", p.ID),
			gin.Params{{Key: "photoId", Value: fmt.Sprint(p.ID)}}, 1, "")
		if ar.Code != http.StatusOK {
			t.Fatalf("approve %d status=%d", i, ar.Code)
		}
	}

	// 6. 3/3 后普通用户再投稿 → 409 dish_gallery_full（投稿阶段即拦截）
	f4 := createTestFile(t, db, 40, 2, models.FileAccessPrivate)
	r4 := performDishPhotoRequest(t, submit.SubmitDishPhoto, http.MethodPost,
		fmt.Sprintf("/api/canteens/%d/dish-photos", canteen.ID),
		gin.Params{{Key: "canteenId", Value: fmt.Sprint(canteen.ID)}},
		2,
		fmt.Sprintf(`{"dish_id":%d,"file_id":%d}`, photo.DishID, f4.ID))
	if r4.Code != http.StatusConflict || !strings.Contains(r4.Body.String(), "dish_gallery_full") {
		t.Fatalf("submit 4th status=%d body=%s want 409 gallery_full", r4.Code, r4.Body.String())
	}

	// 7. 3/3 后管理员再审核 → 409 dish_gallery_full
	var p3 models.CanteenDishPhoto
	db.Where("status = ? AND dish_id = ?", models.DishPhotoStatusApproved, photo.DishID).First(&p3)
	ar4 := performDishPhotoRequest(t, admin.ApproveDishPhoto, http.MethodPost,
		fmt.Sprintf("/api/canteens/dish-photos/%d/approve", p3.ID),
		gin.Params{{Key: "photoId", Value: fmt.Sprint(p3.ID)}}, 1, "")
	if ar4.Code != http.StatusConflict || !strings.Contains(ar4.Body.String(), "already_reviewed") {
		t.Fatalf("re-approve status=%d body=%s want 409 already_reviewed", ar4.Code, ar4.Body.String())
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

	// reject 场景
	fileR := createTestFile(t, db, 50, 2, models.FileAccessPrivate)
	rR := performDishPhotoRequest(t, submit.SubmitDishPhoto, http.MethodPost,
		fmt.Sprintf("/api/canteens/%d/dish-photos", canteen.ID),
		gin.Params{{Key: "canteenId", Value: fmt.Sprint(canteen.ID)}},
		2, fmt.Sprintf(`{"dish_name":"麻辣香锅","file_id":%d}`, fileR.ID))
	if rR.Code != http.StatusCreated {
		t.Fatalf("submit reject case status=%d body=%s", rR.Code, rR.Body.String())
	}
	var pR models.CanteenDishPhoto
	db.First(&pR)

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

	// archive 场景：先 approve 再 archive
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
	appr := performDishPhotoRequest(t, admin.ApproveDishPhoto, http.MethodPost,
		fmt.Sprintf("/api/canteens/dish-photos/%d/approve", pA.ID),
		gin.Params{{Key: "photoId", Value: fmt.Sprint(pA.ID)}}, 1, "")
	if appr.Code != http.StatusOK {
		t.Fatalf("approve archive case status=%d", appr.Code)
	}
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
	unbound := createCanteenTestUser(t, db, 4, "未绑定")
	fileForUnbound := createTestFile(t, db, 70, 4, models.FileAccessPrivate)
	resp := performDishPhotoRequest(t, submit.SubmitDishPhoto, http.MethodPost,
		fmt.Sprintf("/api/canteens/%d/dish-photos", canteen.ID),
		gin.Params{{Key: "canteenId", Value: fmt.Sprint(canteen.ID)}},
		4, fmt.Sprintf(`{"dish_name":"蛋炒饭","file_id":%d}`, fileForUnbound.ID))
	if resp.Code != http.StatusForbidden || !strings.Contains(resp.Body.String(), "edu_binding_required") {
		t.Fatalf("unbound status=%d body=%s", resp.Code, resp.Body.String())
	}
	_ = unbound

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

	// 恰好 40 个字符 → 400 之后的边界：40 字应成功
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

func TestDishPhotoPendingUniqueAndNormalizedReuse(t *testing.T) {
	db := newDishPhotoTestDB(t)
	createVerifiedUser(t, db, 1, "管理员")
	createVerifiedUser(t, db, 2, "学生")
	canteen := models.Canteen{Name: "四食堂", Image: "/uploads/canteen.png", CreatedBy: 1, Verified: true}
	db.Create(&canteen)
	submit := NewCanteenDishPhotoHandler(db)

	// 同一用户同菜两个 pending → conflict
	f1 := createTestFile(t, db, 80, 2, models.FileAccessPrivate)
	r1 := performDishPhotoRequest(t, submit.SubmitDishPhoto, http.MethodPost,
		fmt.Sprintf("/api/canteens/%d/dish-photos", canteen.ID),
		gin.Params{{Key: "canteenId", Value: fmt.Sprint(canteen.ID)}},
		2, fmt.Sprintf(`{"dish_name":" 锅 包 肉 ","file_id":%d}`, f1.ID))
	if r1.Code != http.StatusCreated {
		t.Fatalf("first submit status=%d body=%s", r1.Code, r1.Body.String())
	}
	f2 := createTestFile(t, db, 81, 2, models.FileAccessPrivate)
	r2 := performDishPhotoRequest(t, submit.SubmitDishPhoto, http.MethodPost,
		fmt.Sprintf("/api/canteens/%d/dish-photos", canteen.ID),
		gin.Params{{Key: "canteenId", Value: fmt.Sprint(canteen.ID)}},
		2, fmt.Sprintf(`{"dish_name":"锅包肉","file_id":%d}`, f2.ID))
	if r2.Code != http.StatusConflict || !strings.Contains(r2.Body.String(), "pending_photo_exists") {
		t.Fatalf("second pending status=%d body=%s", r2.Code, r2.Body.String())
	}

	// normalized 复用：第二个用户用 "锅 包 肉" 提交 → 复用同一 dish
	createVerifiedUser(t, db, 3, "学生三")
	f3 := createTestFile(t, db, 82, 3, models.FileAccessPrivate)
	r3 := performDishPhotoRequest(t, submit.SubmitDishPhoto, http.MethodPost,
		fmt.Sprintf("/api/canteens/%d/dish-photos", canteen.ID),
		gin.Params{{Key: "canteenId", Value: fmt.Sprint(canteen.ID)}},
		3, fmt.Sprintf(`{"dish_name":"锅 包 肉","file_id":%d}`, f3.ID))
	if r3.Code != http.StatusCreated {
		t.Fatalf("third submit status=%d body=%s", r3.Code, r3.Body.String())
	}
	var dishCount int64
	db.Model(&models.CanteenDish{}).Where("normalized_name = ?", "锅包肉").Count(&dishCount)
	if dishCount != 1 {
		t.Fatalf("normalized dish count=%d want 1 (reuse)", dishCount)
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
	// dish2 改名为已存在的 "秘制红烧肉" → 409
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

// 辅助：JSON 解析响应中的某个字段
func decodeJSONBody(t *testing.T, body string) map[string]interface{} {
	t.Helper()
	var m map[string]interface{}
	if err := json.Unmarshal([]byte(body), &m); err != nil {
		t.Fatalf("decode: %v", err)
	}
	return m
}
