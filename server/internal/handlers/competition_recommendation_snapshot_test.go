package handlers

import (
	"encoding/json"
	"errors"
	"strings"
	"testing"
	"time"

	"shenliyuan/internal/models"
)

func TestCreateCompetitionRecommendationSnapshotUsesServerResult(t *testing.T) {
	db := newCompetitionTestDB(t)
	handler := NewCompetitionHandler(db)
	verifiedAt := time.Now().UTC()
	user := models.User{
		StudentID: "snapshot-user", PasswordHash: "x", Nickname: "快照用户",
		EduAuthorized: true, EduBound: true, StudentVerifiedAt: &verifiedAt,
		EduGrade: "2023", EduCollege: "信息科学与工程学院", EduMajor: "计算机科学与技术",
	}
	if err := db.Create(&user).Error; err != nil {
		t.Fatal(err)
	}
	preference := models.UserCompetitionPreference{
		UserID: user.ID, Goals: jsonArray([]string{"ability"}), DirectionTags: jsonArray([]string{"程序设计"}),
		SkillTags: jsonArray([]string{"C++"}), PreferredRoles: jsonArray([]string{"developer"}), WeeklyHours: 7,
		ExperienceLevel: "beginner",
	}
	if err := db.Create(&preference).Error; err != nil {
		t.Fatal(err)
	}
	event := models.CompetitionEvent{
		Title: "C++ 程序设计赛", Status: "published", Version: 3,
		EligibleMajors: jsonArray([]string{"计算机科学与技术"}), CompetitionRating: "A",
		CompetitionID: "NAT-SNAPSHOT-1", DatasetVersion: "catalog-v1",
		RecordHash: strings.Repeat("a", 64), SearchDisplayAllowed: true,
		CandidatePoolAllowed: true, AIMode: "candidate_explanation",
	}
	if err := db.Create(&event).Error; err != nil {
		t.Fatal(err)
	}

	now := time.Date(2026, 7, 23, 10, 0, 0, 0, time.UTC)
	snapshot, dto, err := handler.createCompetitionRecommendationSnapshot(db, user.ID, event.ID, now)
	if err != nil {
		t.Fatal(err)
	}
	if snapshot.EventVersion != 3 || snapshot.EventTitle != event.Title {
		t.Fatalf("unexpected snapshot: %+v", snapshot)
	}
	if snapshot.PersonalizedScore != nil || snapshot.RecommendationTier != "" ||
		dto.PersonalizedScore != nil || dto.RecommendationTier != "" {
		t.Fatalf("snapshot exposed deprecated scores: snapshot=%+v dto=%+v", snapshot, dto)
	}
	if len(snapshot.FitReasons) == 0 || len(dto.FitReasons) != 1 {
		t.Fatalf("missing deterministic result: snapshot=%+v dto=%+v", snapshot, dto)
	}
	if snapshot.CompetitionID != event.CompetitionID ||
		snapshot.DatasetVersion != event.DatasetVersion ||
		snapshot.RecordHash != event.RecordHash ||
		snapshot.Mode != "candidate_explanation" ||
		snapshot.GroupKey == "" ||
		len(snapshot.MatchDimensions) == 0 {
		t.Fatalf("missing catalog invalidation fields: %+v", snapshot)
	}
	if snapshot.ExpiresAt.Sub(snapshot.CreatedAt) != 30*time.Minute {
		t.Fatalf("ttl=%s", snapshot.ExpiresAt.Sub(snapshot.CreatedAt))
	}
	if len(snapshot.CapabilityHash) != 64 || len(snapshot.EventCriticalHash) != 64 {
		t.Fatalf("invalid hashes: %+v", snapshot)
	}
	originalCriticalHash := snapshot.EventCriticalHash
	if err := db.Model(&event).Update("record_hash", strings.Repeat("b", 64)).Error; err != nil {
		t.Fatal(err)
	}
	refreshed, _, err := handler.buildCompetitionRecommendationSnapshot(
		db,
		user.ID,
		event.ID,
		now,
	)
	if err != nil {
		t.Fatal(err)
	}
	if refreshed.EventCriticalHash == originalCriticalHash {
		t.Fatal("record_hash 变化后快照未失效")
	}
	encoded, err := json.Marshal(snapshot)
	if err != nil {
		t.Fatal(err)
	}
	for _, forbidden := range []string{"evidence", "verification_note", "verified_by", "gpa", "graduation"} {
		if json.Valid(encoded) && containsJSONKey(encoded, forbidden) {
			t.Fatalf("snapshot leaked %q: %s", forbidden, encoded)
		}
	}
}

func TestCreateCompetitionRecommendationSnapshotRejectsUnavailableAndDuplicate(t *testing.T) {
	db := newCompetitionTestDB(t)
	handler := NewCompetitionHandler(db)
	user := models.User{StudentID: "snapshot-reject", PasswordHash: "x", Nickname: "用户"}
	if err := db.Create(&user).Error; err != nil {
		t.Fatal(err)
	}
	event := models.CompetitionEvent{Title: "赛事", Status: "published"}
	if err := db.Create(&event).Error; err != nil {
		t.Fatal(err)
	}
	if _, _, err := handler.createCompetitionRecommendationSnapshot(db, user.ID, event.ID, time.Now()); !errors.Is(err, errCompetitionProfileUnavailable) {
		t.Fatalf("err=%v", err)
	}
}

func containsJSONKey(encoded []byte, key string) bool {
	var value map[string]interface{}
	if json.Unmarshal(encoded, &value) != nil {
		return false
	}
	_, exists := value[key]
	return exists
}
