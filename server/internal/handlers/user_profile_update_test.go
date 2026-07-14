package handlers

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/gin-gonic/gin"
	"github.com/glebarez/sqlite"
	"gorm.io/gorm"

	"shenliyuan/internal/models"
)

func newUserProfileUpdateTestDB(t *testing.T) *gorm.DB {
	t.Helper()
	db, err := gorm.Open(sqlite.Open(":memory:"), &gorm.Config{})
	if err != nil {
		t.Fatalf("open database: %v", err)
	}
	if err := db.AutoMigrate(&models.User{}); err != nil {
		t.Fatalf("migrate users: %v", err)
	}
	return db
}

func ptrStr(s string) *string {
	return &s
}

func TestUserProfileUpdate(t *testing.T) {
	gin.SetMode(gin.TestMode)
	db := newUserProfileUpdateTestDB(t)

	// Seed user
	user := models.User{
		Nickname: "Original Name",
		Gender:   "female",
	}
	db.Create(&user)

	handler := NewUserHandler(db)
	router := gin.Default()
	// Mock middleware to set user_id
	router.Use(func(c *gin.Context) {
		c.Set("user_id", user.ID)
		c.Next()
	})
	router.PUT("/user/profile", handler.UpdateProfile)

	tests := []struct {
		name           string
		input          UpdateProfileInput
		expectedStatus int
		expectedName   string
		expectedGender string
	}{
		{
			name:           "Valid nickname and valid gender",
			input:          UpdateProfileInput{Nickname: "New Name", Gender: ptrStr("male")},
			expectedStatus: http.StatusOK,
			expectedName:   "New Name",
			expectedGender: "male",
		},
		{
			name:           "Omit gender (pointer is nil), keeps old gender",
			input:          UpdateProfileInput{Nickname: "Omit Gender"},
			expectedStatus: http.StatusOK,
			expectedName:   "Omit Gender",
			expectedGender: "male", // Remains male from the previous successful test
		},
		{
			name:           "Empty gender string sets to empty (secrecy)",
			input:          UpdateProfileInput{Nickname: "Empty Gender", Gender: ptrStr("")},
			expectedStatus: http.StatusOK,
			expectedName:   "Empty Gender",
			expectedGender: "",
		},
		{
			name:           "Invalid gender returns 400",
			input:          UpdateProfileInput{Nickname: "Invalid Gender", Gender: ptrStr("unknown")},
			expectedStatus: http.StatusBadRequest,
		},
		{
			name:           "Empty nickname (or whitespace) returns 400",
			input:          UpdateProfileInput{Nickname: "   ", Gender: ptrStr("female")},
			expectedStatus: http.StatusBadRequest,
		},
		{
			name:           "Nickname length > 20 returns 400",
			input:          UpdateProfileInput{Nickname: "这是一个超长的名字这真的非常长不可能合法超过二十个字符了"},
			expectedStatus: http.StatusBadRequest,
		},
		{
			name:           "Nickname length = 20 saves successfully",
			input:          UpdateProfileInput{Nickname: "这是一二三四五六七八九十一二三四五六七八九十"},
			expectedStatus: http.StatusOK,
			expectedName:   "这是一二三四五六七八九十一二三四五六七八九十",
			expectedGender: "", // Remains empty from the third test
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			body, _ := json.Marshal(tc.input)
			req := httptest.NewRequest(http.MethodPut, "/user/profile", bytes.NewReader(body))
			req.Header.Set("Content-Type", "application/json")
			w := httptest.NewRecorder()

			router.ServeHTTP(w, req)

			if w.Code != tc.expectedStatus {
				t.Fatalf("expected status %d, got %d. Body: %s", tc.expectedStatus, w.Code, w.Body.String())
			}

			if tc.expectedStatus == http.StatusOK {
				var updatedUser models.User
				db.First(&updatedUser, user.ID)

				if updatedUser.Nickname != tc.expectedName {
					t.Errorf("expected nickname %q, got %q", tc.expectedName, updatedUser.Nickname)
				}
				if updatedUser.Gender != tc.expectedGender {
					t.Errorf("expected gender %q, got %q", tc.expectedGender, updatedUser.Gender)
				}
			}
		})
	}
}
