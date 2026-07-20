package models

import (
	"path/filepath"
	"testing"

	"github.com/glebarez/sqlite"
	"gorm.io/gorm"
)

func TestEnsurePollSchemaBackfillAndConstraints(t *testing.T) {
	db, err := gorm.Open(sqlite.Open(filepath.Join(t.TempDir(), "poll-schema.db")), &gorm.Config{})
	if err != nil {
		t.Fatal(err)
	}
	sqlDB, err := db.DB()
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = sqlDB.Close() })
	if err := db.AutoMigrate(&Post{}, &Poll{}, &PollOption{}, &PollBallot{}, &PollBallotChoice{}); err != nil {
		t.Fatal(err)
	}
	posts := []Post{
		{BoardID: BoardShuitie, AuthorID: 1, ContentKind: PostContentKindNormal},
		{BoardID: BoardShuitie, AuthorID: 1, ContentKind: PostContentKindPoll, PostType: "poll"},
	}
	if err := db.Create(&posts).Error; err != nil {
		t.Fatal(err)
	}
	if err := EnsurePollSchema(db); err != nil {
		t.Fatal(err)
	}
	if err := EnsurePollSchema(db); err != nil {
		t.Fatalf("重复迁移失败: %v", err)
	}
	var got []Post
	if err := db.Order("id ASC").Find(&got).Error; err != nil {
		t.Fatal(err)
	}
	if got[0].PostType != "campus_life" {
		t.Fatalf("普通水帖 post_type=%q", got[0].PostType)
	}
	if got[1].PostType != "poll" || got[1].ContentKind != PostContentKindPoll {
		t.Fatalf("投票帖被错误回填: %#v", got[1])
	}

	poll := Poll{PostID: got[1].ID, Category: PollCategoryOther, SelectionMode: PollSelectionSingle, MaxChoices: 1, ResultsVisibility: PollResultsAlways, Status: PollStatusActive}
	if err := db.Create(&poll).Error; err != nil {
		t.Fatal(err)
	}
	if err := db.Create(&Poll{PostID: got[1].ID, Category: PollCategoryOther, SelectionMode: PollSelectionSingle, MaxChoices: 1, ResultsVisibility: PollResultsAlways}).Error; err == nil {
		t.Fatal("同一帖子应只能关联一个投票")
	}
	ballot := PollBallot{PollID: poll.ID, UserID: 9}
	if err := db.Create(&ballot).Error; err != nil {
		t.Fatal(err)
	}
	if err := db.Create(&PollBallot{PollID: poll.ID, UserID: 9}).Error; err == nil {
		t.Fatal("同一用户在同一投票中应只能有一张选票")
	}
	option := PollOption{PollID: poll.ID, Text: "选项", SortOrder: 0}
	if err := db.Create(&option).Error; err != nil {
		t.Fatal(err)
	}
	choice := PollBallotChoice{BallotID: ballot.ID, OptionID: option.ID}
	if err := db.Create(&choice).Error; err != nil {
		t.Fatal(err)
	}
	if err := db.Create(&PollBallotChoice{BallotID: ballot.ID, OptionID: option.ID}).Error; err == nil {
		t.Fatal("同一选票不能重复选择同一选项")
	}
}
