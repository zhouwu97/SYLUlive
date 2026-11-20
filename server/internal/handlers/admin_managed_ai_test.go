package handlers

import (
	"encoding/json"
	"github.com/gin-gonic/gin"
	"github.com/glebarez/sqlite"
	"gorm.io/gorm"
	"net/http/httptest"
	"shenliyuan/internal/models"
	"testing"
)

func TestManagedAIAdminIdentityAndHumanList(t *testing.T) {
	db, err := gorm.Open(sqlite.Open(":memory:"), &gorm.Config{})
	if err != nil {
		t.Fatal(err)
	}
	if err = db.AutoMigrate(&models.User{}, &models.ManagedBot{}, &models.AcademicIdentityBinding{}); err != nil {
		t.Fatal(err)
	}
	for _, u := range []models.User{{ID: 1, Nickname: "创建者", PasswordHash: "test", Role: models.RoleUser}, {ID: 2, Nickname: "[AI] 小鱼", PasswordHash: "test", Role: models.RoleUser, AccountStatus: "bot"}} {
		if err = db.Create(&u).Error; err != nil {
			t.Fatal(err)
		}
	}
	if err = db.Create(&models.ManagedBot{OwnerID: 1, UserID: 2, Enabled: true}).Error; err != nil {
		t.Fatal(err)
	}
	for _, tc := range []struct {
		url string
		ai  bool
	}{{"/api/super/users", false}, {"/api/super/users?kind=ai", true}} {
		w := httptest.NewRecorder()
		c, _ := gin.CreateTestContext(w)
		c.Request = httptest.NewRequest("GET", tc.url, nil)
		NewSuperAdminHandler(db).GetUsers(c)
		if w.Code != 200 {
			t.Fatalf("%d %s", w.Code, w.Body.String())
		}
		var rows []map[string]interface{}
		if err = json.Unmarshal(w.Body.Bytes(), &rows); err != nil {
			t.Fatal(err)
		}
		if len(rows) != 1 {
			t.Fatalf("unexpected rows %s", w.Body.String())
		}
		if tc.ai {
			if rows[0]["owner_id"] != float64(1) || rows[0]["name"] != "小鱼" {
				t.Fatal(rows)
			}
			if _, ok := rows[0]["id"].(string); !ok {
				t.Fatal("AI must have a separate identifier")
			}
			if _, ok := rows[0]["actor_id"]; ok {
				t.Fatal("internal actor exposed")
			}
		} else if rows[0]["id"] != float64(1) {
			t.Fatal(rows)
		}
	}
}
