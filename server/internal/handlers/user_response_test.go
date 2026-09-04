package handlers

import (
	"encoding/json"
	"testing"
	"time"

	"shenliyuan/internal/models"
)

func TestPublicAndSelfUserResponsesKeepTheirBoundaries(t *testing.T) {
	user := models.User{
		ID:               7,
		StudentID:        "2026000001",
		Nickname:         "测试用户",
		Gender:           "female",
		Role:             models.RoleAdmin,
		CreditScore:      88,
		EduStudentID:     "2026000001",
		EduBound:         true,
		EduAuthorized:    true,
		EduGrade:         "2026",
		EduCollege:       "计算机学院",
		EduMajor:         "软件工程",
		IsCheckedInToday: true,
		CreatedAt:        time.Date(2026, 7, 12, 0, 0, 0, 0, time.UTC),
	}

	publicBody, err := json.Marshal(publicUserResponse(user))
	if err != nil {
		t.Fatalf("marshal public response: %v", err)
	}
	var public map[string]interface{}
	if err := json.Unmarshal(publicBody, &public); err != nil {
		t.Fatalf("unmarshal public response: %v", err)
	}
	for _, privateField := range []string{"student_id", "role", "edu_bound", "gender"} {
		if _, exists := public[privateField]; exists {
			t.Fatalf("public response leaked %s: %s", privateField, publicBody)
		}
	}
	if _, exists := public["credit_score"]; !exists {
		t.Fatalf("public response missing credit_score: %s", publicBody)
	}

	selfBody, err := json.Marshal(selfUserResponse(user, models.LegalConsentStateActive))
	if err != nil {
		t.Fatalf("marshal self response: %v", err)
	}
	var self map[string]interface{}
	if err := json.Unmarshal(selfBody, &self); err != nil {
		t.Fatalf("unmarshal self response: %v", err)
	}
	for _, requiredField := range []string{"student_id", "role", "edu_bound", "credit_score", "gender", "is_checked_in_today"} {
		if _, exists := self[requiredField]; !exists {
			t.Fatalf("self response missing %s: %s", requiredField, selfBody)
		}
	}
}
