package handlers

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"shenliyuan/internal/models"

	"github.com/gin-gonic/gin"
	"gorm.io/driver/sqlite"
	"gorm.io/gorm"
)

func newAppealAccessTestDB(t *testing.T) *gorm.DB {
	t.Helper()
	db, err := gorm.Open(sqlite.Open("file:appealaccess?mode=memory&cache=shared"), &gorm.Config{})
	if err != nil {
		t.Fatal(err)
	}
	if err := db.AutoMigrate(&models.User{}, &models.Post{}, &models.Appeal{}, &models.AppealVote{}); err != nil {
		t.Fatal(err)
	}
	return db
}

func TestAppealDetailEnforcesAccessAndUsesPrivacyDTO(t *testing.T) {
	gin.SetMode(gin.TestMode)
	db := newAppealAccessTestDB(t)
	users := []models.User{
		{ID: 1, StudentID: "secret-student", QQ: "secret-qq", Nickname: "申诉人", DeviceToken: "secret-device", Role: models.RoleUser},
		{ID: 2, StudentID: "admin-student", Nickname: "管理员", Role: models.RoleAdmin},
		{ID: 3, StudentID: "jury-student", Nickname: "陪审员", Role: models.RoleUser},
		{ID: 4, StudentID: "other-student", Nickname: "无关用户", Role: models.RoleUser},
	}
	if err := db.Create(&users).Error; err != nil {
		t.Fatal(err)
	}
	post := models.Post{ID: 1, Title: "申诉帖子", Content: "正文", AuthorID: 1, BoardID: models.BoardShuitie, Status: models.PostStatusDeleted}
	if err := db.Create(&post).Error; err != nil {
		t.Fatal(err)
	}
	appeal := models.Appeal{ID: 1, PostID: 1, AppellantID: 1, AdminID: 2, Status: models.AppealStatusPending, RequiredVotes: 1}
	if err := db.Create(&appeal).Error; err != nil {
		t.Fatal(err)
	}
	if err := db.Create(&models.AppealVote{AppealID: 1, VoterID: 3}).Error; err != nil {
		t.Fatal(err)
	}

	handler := NewAppealHandler(db)
	request := func(userID uint, role models.Role) *httptest.ResponseRecorder {
		recorder := httptest.NewRecorder()
		context, _ := gin.CreateTestContext(recorder)
		context.Request = httptest.NewRequest(http.MethodGet, "/api/appeals/1", nil)
		context.Params = gin.Params{{Key: "id", Value: "1"}}
		context.Set("user_id", userID)
		context.Set("role", string(role))
		handler.GetOne(context)
		return recorder
	}

	if response := request(4, models.RoleUser); response.Code != http.StatusForbidden {
		t.Fatalf("无关用户应被拒绝，得到 %d", response.Code)
	}
	response := request(3, models.RoleUser)
	if response.Code != http.StatusOK {
		t.Fatalf("陪审员应可查看，得到 %d: %s", response.Code, response.Body.String())
	}
	body := response.Body.String()
	for _, secret := range []string{"secret-student", "secret-qq", "secret-device", "student_id", "device_token", "token_version"} {
		if strings.Contains(body, secret) {
			t.Fatalf("申诉 DTO 泄露敏感字段 %q: %s", secret, body)
		}
	}
	var decoded map[string]interface{}
	if err := json.Unmarshal(response.Body.Bytes(), &decoded); err != nil {
		t.Fatal(err)
	}
	if _, ok := decoded["appeal"]; !ok {
		t.Fatalf("缺少 appeal 响应: %s", body)
	}
}
