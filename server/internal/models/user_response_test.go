package models

import (
	"encoding/json"
	"testing"
)

func TestPostAndReplySerializePublicAuthors(t *testing.T) {
	author := User{
		ID:           1,
		StudentID:    "2026000001",
		Nickname:     "公开作者",
		Role:         RoleAdmin,
		CreditScore:  80,
		EduStudentID: "2026000001",
		EduBound:     true,
	}

	for _, payload := range []interface{}{
		Post{ID: 10, AuthorID: author.ID, Author: author},
		Reply{ID: 11, PostID: 10, AuthorID: author.ID, Author: author},
	} {
		body, err := json.Marshal(payload)
		if err != nil {
			t.Fatalf("marshal payload: %v", err)
		}
		var decoded struct {
			Author map[string]interface{} `json:"author"`
		}
		if err := json.Unmarshal(body, &decoded); err != nil {
			t.Fatalf("unmarshal payload: %v", err)
		}
		for _, privateField := range []string{"student_id", "role", "edu_student_id", "edu_bound", "credit_score"} {
			if _, exists := decoded.Author[privateField]; exists {
				t.Fatalf("author leaked %s: %s", privateField, body)
			}
		}
		if decoded.Author["nickname"] != author.Nickname {
			t.Fatalf("public author missing nickname: %s", body)
		}
	}
}
