package services

import (
	"errors"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/glebarez/sqlite"
	"gorm.io/gorm"

	"shenliyuan/internal/models"
)

func newPollServiceTestDB(t *testing.T) *gorm.DB {
	t.Helper()
	db, err := gorm.Open(sqlite.Open(filepath.Join(t.TempDir(), "poll-service.db")), &gorm.Config{})
	if err != nil {
		t.Fatal(err)
	}
	sqlDB, err := db.DB()
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = sqlDB.Close() })
	if err := db.AutoMigrate(
		&models.User{}, &models.ExpLog{}, &models.File{}, &models.FileUploadGrant{},
		&models.Post{}, &models.PostImage{}, &models.Poll{}, &models.PollOption{},
		&models.PollBallot{}, &models.PollBallotChoice{},
	); err != nil {
		t.Fatal(err)
	}
	return db
}

func pollInput(now time.Time) CreatePollInput {
	return CreatePollInput{
		Title: "午休时间是否应该延长", Description: "选择更适合你的安排", Category: models.PollCategoryCampusLife,
		SelectionMode: models.PollSelectionSingle, MaxChoices: 1, ResultsVisibility: models.PollResultsAfterVote,
		AllowChange: true, EndsAt: now.Add(72 * time.Hour), Options: []string{"维持现状", "延长半小时", "延长一小时"},
	}
}

func seedPollUser(t *testing.T, db *gorm.DB, suffix string) models.User {
	t.Helper()
	user := models.User{StudentID: "poll-" + suffix, PasswordHash: "x", Nickname: "测试用户" + suffix, Role: models.RoleUser}
	if err := db.Create(&user).Error; err != nil {
		t.Fatal(err)
	}
	return user
}

func requirePollCode(t *testing.T, err error, code string) {
	t.Helper()
	var pollErr *PollError
	if !errors.As(err, &pollErr) || pollErr.Code != code {
		t.Fatalf("error=%v, want code=%s", err, code)
	}
}

func TestPollServiceCreateAndResultVisibility(t *testing.T) {
	db := newPollServiceTestDB(t)
	now := time.Date(2026, 7, 18, 12, 0, 0, 0, time.Local)
	owner := seedPollUser(t, db, "owner")
	voter := seedPollUser(t, db, "voter")
	service := NewPollService(db)
	service.SetNowForTest(func() time.Time { return now })

	created, err := service.Create(owner.ID, string(owner.Role), pollInput(now))
	if err != nil {
		t.Fatal(err)
	}
	if created.ContentKind != models.PostContentKindPoll || created.PostType != "poll" || created.BoardID != models.BoardShuitie {
		t.Fatalf("投票帖子字段错误: %#v", created)
	}
	if created.WaterSectionAuthorMeta != nil || created.PollMeta == nil {
		t.Fatalf("投票摘要或版块等级错误: %#v", created)
	}
	if created.PollMeta.ResultsVisible || created.PollMeta.Options[0].VoteCount != nil {
		t.Fatal("after_vote 在未投票时泄露了结果")
	}

	optionID := created.PollMeta.Options[1].ID
	updated, err := service.PutBallot(created.PollMeta.ID, voter.ID, []uint{optionID})
	if err != nil {
		t.Fatal(err)
	}
	if !updated.PollMeta.HasVoted || !updated.PollMeta.ResultsVisible || updated.PollMeta.ParticipantCount != 1 {
		t.Fatalf("投票后摘要错误: %#v", updated.PollMeta)
	}
	if updated.PollMeta.Options[1].VoteCount == nil || *updated.PollMeta.Options[1].VoteCount != 1 || !updated.PollMeta.Options[1].IsChosen {
		t.Fatalf("选项结果错误: %#v", updated.PollMeta.Options[1])
	}

	// 相同 PUT 是幂等操作，不得重复增加计数。
	repeated, err := service.PutBallot(created.PollMeta.ID, voter.ID, []uint{optionID})
	if err != nil {
		t.Fatal(err)
	}
	if repeated.PollMeta.ParticipantCount != 1 || repeated.PollMeta.ChoiceCount == nil || *repeated.PollMeta.ChoiceCount != 1 {
		t.Fatalf("重复 PUT 改变计数: %#v", repeated.PollMeta)
	}

	newOptionID := created.PollMeta.Options[2].ID
	changed, err := service.PutBallot(created.PollMeta.ID, voter.ID, []uint{newOptionID})
	if err != nil {
		t.Fatal(err)
	}
	if *changed.PollMeta.Options[1].VoteCount != 0 || *changed.PollMeta.Options[2].VoteCount != 1 || changed.PollMeta.ParticipantCount != 1 {
		t.Fatalf("改票计数错误: %#v", changed.PollMeta.Options)
	}
}

func TestPollServiceValidationAndRulesLock(t *testing.T) {
	db := newPollServiceTestDB(t)
	now := time.Date(2026, 7, 18, 12, 0, 0, 0, time.Local)
	owner := seedPollUser(t, db, "owner")
	voter := seedPollUser(t, db, "voter")
	service := NewPollService(db)
	service.SetNowForTest(func() time.Time { return now })

	invalid := pollInput(now)
	invalid.Options = []string{"重复", " 重复 "}
	_, err := service.Create(owner.ID, string(owner.Role), invalid)
	requirePollCode(t, err, PollCodeInvalidOption)

	input := pollInput(now)
	created, err := service.Create(owner.ID, string(owner.Role), input)
	if err != nil {
		t.Fatal(err)
	}
	_, err = service.PutBallot(created.PollMeta.ID, voter.ID, []uint{created.PollMeta.Options[0].ID, created.PollMeta.Options[1].ID})
	requirePollCode(t, err, PollCodeInvalidChoiceCount)

	otherInput := pollInput(now)
	otherInput.Title = "另一个投票"
	other, err := service.Create(voter.ID, string(voter.Role), otherInput)
	if err != nil {
		t.Fatal(err)
	}
	_, err = service.PutBallot(created.PollMeta.ID, voter.ID, []uint{other.PollMeta.Options[0].ID})
	requirePollCode(t, err, PollCodeInvalidOption)

	if _, err := service.PutBallot(created.PollMeta.ID, voter.ID, []uint{created.PollMeta.Options[0].ID}); err != nil {
		t.Fatal(err)
	}
	input.Title = "试图修改标题"
	_, err = service.Update(created.PollMeta.ID, owner.ID, string(owner.Role), input)
	requirePollCode(t, err, PollCodeRulesLocked)

	input = pollInput(now)
	input.Description = "只修改补充说明"
	updated, err := service.Update(created.PollMeta.ID, owner.ID, string(owner.Role), input)
	if err != nil || updated.Content != input.Description {
		t.Fatalf("有票后修改说明失败: post=%#v err=%v", updated, err)
	}
	input.Description = strings.Repeat("超长", 501)
	_, err = service.Update(created.PollMeta.ID, owner.ID, string(owner.Role), input)
	requirePollCode(t, err, PollCodeInvalidInput)
}

func TestPollServiceCloseDeleteAndRecalculate(t *testing.T) {
	db := newPollServiceTestDB(t)
	now := time.Date(2026, 7, 18, 12, 0, 0, 0, time.Local)
	owner := seedPollUser(t, db, "owner")
	voter := seedPollUser(t, db, "voter")
	service := NewPollService(db)
	service.SetNowForTest(func() time.Time { return now })
	input := pollInput(now)
	input.ResultsVisibility = models.PollResultsAfterEnd
	created, err := service.Create(owner.ID, string(owner.Role), input)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := service.PutBallot(created.PollMeta.ID, voter.ID, []uint{created.PollMeta.Options[0].ID}); err != nil {
		t.Fatal(err)
	}
	closed, err := service.Close(created.PollMeta.ID, owner.ID, string(owner.Role))
	if err != nil {
		t.Fatal(err)
	}
	if closed.PollMeta.EffectiveStatus != models.PollStatusClosed || !closed.PollMeta.ResultsVisible {
		t.Fatalf("关闭后的结果状态错误: %#v", closed.PollMeta)
	}
	_, err = service.Update(created.PollMeta.ID, owner.ID, string(owner.Role), input)
	requirePollCode(t, err, PollCodeEnded)
	_, err = service.PutBallot(created.PollMeta.ID, owner.ID, []uint{created.PollMeta.Options[1].ID})
	requirePollCode(t, err, PollCodeEnded)

	if err := db.Model(&models.Poll{}).Where("id = ?", created.PollMeta.ID).Updates(map[string]interface{}{"participant_count": 99, "choice_count": 88}).Error; err != nil {
		t.Fatal(err)
	}
	if err := db.Model(&models.PollOption{}).Where("poll_id = ?", created.PollMeta.ID).Update("vote_count", 77).Error; err != nil {
		t.Fatal(err)
	}
	if err := RecalculatePollCounts(db, created.PollMeta.ID); err != nil {
		t.Fatal(err)
	}
	var poll models.Poll
	if err := db.First(&poll, created.PollMeta.ID).Error; err != nil {
		t.Fatal(err)
	}
	if poll.ParticipantCount != 1 || poll.ChoiceCount != 1 {
		t.Fatalf("统计重算错误: %#v", poll)
	}

	if err := service.Delete(created.PollMeta.ID, voter.ID, string(voter.Role)); err == nil {
		t.Fatal("非作者不应删除投票")
	}
	if err := service.Delete(created.PollMeta.ID, owner.ID, string(owner.Role)); err != nil {
		t.Fatal(err)
	}
	if _, err := service.Get(created.PollMeta.ID, 0); err == nil {
		t.Fatal("删除后的公开详情应返回不存在")
	}
}
