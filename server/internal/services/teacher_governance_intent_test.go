package services

import (
	"errors"
	"testing"

	"shenliyuan/internal/models"

	"gorm.io/gorm"
)

// govIntentFixture 治理预览凭证意图绑定用例的最小数据：
// 同学科 A/B 两个重复教师，跨学科同名教师 C，以及一条指向 B 的教师别名。
type govIntentFixture struct {
	db       *gorm.DB
	admin    models.User
	subjectA *models.CourseSubject
	subjectB *models.CourseSubject
	keeperA  *models.Teacher
	loserB   *models.Teacher
	loserC   *models.Teacher
	alias    *models.TeacherAlias
}

func newGovIntentFixture(t *testing.T) *govIntentFixture {
	t.Helper()
	db := newGovTestDB(t)
	f := &govIntentFixture{db: db}

	admin := models.User{Nickname: "超级管理员", Role: "admin"}
	if err := db.Create(&admin).Error; err != nil {
		t.Fatalf("创建管理员失败: %v", err)
	}
	f.admin = admin

	subjectA := models.CourseSubject{Name: "高等数学A1", NormalizedName: models.NormalizeCourseSubjectName("高等数学A1"), Verified: true}
	subjectB := models.CourseSubject{Name: "线性代数", NormalizedName: models.NormalizeCourseSubjectName("线性代数"), Verified: true}
	if err := db.Create(&subjectA).Error; err != nil {
		t.Fatalf("创建学科失败: %v", err)
	}
	if err := db.Create(&subjectB).Error; err != nil {
		t.Fatalf("创建学科失败: %v", err)
	}
	f.subjectA, f.subjectB = &subjectA, &subjectB

	newTeacher := func(name string, subject *models.CourseSubject) *models.Teacher {
		teacher := models.Teacher{
			Name:            name,
			Course:          subject.Name,
			CourseSubjectID: &subject.ID,
			NameNormalized:  models.NormalizeTeacherName(name),
			Verified:        true,
		}
		if err := db.Create(&teacher).Error; err != nil {
			t.Fatalf("创建教师 %s 失败: %v", name, err)
		}
		return &teacher
	}
	f.keeperA = newTeacher("张三", &subjectA)
	f.loserB = newTeacher("张三老师", &subjectA)
	f.loserC = newTeacher("张三教授", &subjectB)

	alias := models.TeacherAlias{
		TeacherID:       f.loserB.ID,
		CourseSubjectID: subjectA.ID,
		Alias:           "老张",
		NormalizedAlias: models.NormalizeTeacherName("老张"),
		Source:          "admin",
	}
	if err := db.Create(&alias).Error; err != nil {
		t.Fatalf("创建教师别名失败: %v", err)
	}
	f.alias = &alias
	return f
}

func (f *govIntentFixture) service() *TeacherGovernanceService {
	return NewTeacherGovernanceService(f.db)
}

// mergedInto 返回教师当前的合并指向，nil 表示仍是活动教师。
func (f *govIntentFixture) mergedInto(t *testing.T, teacherID uint) *uint {
	t.Helper()
	var row models.Teacher
	if err := f.db.First(&row, teacherID).Error; err != nil {
		t.Fatalf("读取教师 #%d 失败: %v", teacherID, err)
	}
	return row.MergedIntoID
}

// requireStaleToken 断言执行被「凭证与当前预览不一致」这一条拦下，而不是因为别的业务冲突。
func requireStaleToken(t *testing.T, err error) {
	t.Helper()
	if err == nil {
		t.Fatalf("旧预览凭证应当被拒绝，实际执行成功")
	}
	var govErr *TeacherGovernanceError
	if !errors.As(err, &govErr) || govErr.Code != CodeGovernanceSnapshotStale {
		t.Fatalf("应返回 %s，实际 %v", CodeGovernanceSnapshotStale, err)
	}
}

// GOV-01：预览「保留 A、合并 B」后，用同一凭证执行「保留 B、合并 A」必须被拒绝。
func TestGovernanceTokenBindsKeeperRole(t *testing.T) {
	f := newGovIntentFixture(t)
	svc := f.service()

	preview, err := svc.PreviewMerge(MergeInput{KeeperID: f.keeperA.ID, LoserIDs: []uint{f.loserB.ID}})
	if err != nil {
		t.Fatalf("预览失败: %v", err)
	}

	swapped := MergeInput{
		KeeperID:      f.loserB.ID,
		LoserIDs:      []uint{f.keeperA.ID},
		SnapshotToken: preview.SnapshotToken,
	}
	_, err = svc.Merge(f.admin.ID, swapped)
	if err == nil {
		t.Fatalf("旧预览凭证被反向意图复用：A(#%d) 已并入 #%v", f.keeperA.ID, f.mergedInto(t, f.keeperA.ID))
	}
	requireStaleToken(t, err)
	if f.mergedInto(t, f.keeperA.ID) != nil || f.mergedInto(t, f.loserB.ID) != nil {
		t.Fatalf("被拒绝的合并不得改动教师实体")
	}
}

// GOV-02：别名策略在预览后被改动，旧凭证必须失效。
func TestGovernanceTokenBindsAliasStrategy(t *testing.T) {
	f := newGovIntentFixture(t)
	svc := f.service()

	base := MergeInput{KeeperID: f.keeperA.ID, LoserIDs: []uint{f.loserB.ID}}
	preview, err := svc.PreviewMerge(base)
	if err != nil {
		t.Fatalf("预览失败: %v", err)
	}

	registerFalse := false
	input := base
	input.RegisterTeacherAliases = &registerFalse
	input.SnapshotToken = preview.SnapshotToken
	_, err = svc.Merge(f.admin.ID, input)
	requireStaleToken(t, err)
	if f.mergedInto(t, f.loserB.ID) != nil {
		t.Fatalf("改变别名登记策略后旧凭证仍然执行了合并")
	}
}

// GOV-02：课程归并决策在预览后被改动，旧凭证必须失效。
func TestGovernanceTokenBindsSubjectDecision(t *testing.T) {
	f := newGovIntentFixture(t)
	svc := f.service()

	// 跨学科 loser C：预览时决定只重挂教师、不合并课程实体。
	base := MergeInput{
		KeeperID: f.keeperA.ID,
		LoserIDs: []uint{f.loserC.ID},
		CourseMerges: []CourseMergeDecision{{
			LoserSubjectID:  f.subjectB.ID,
			KeeperSubjectID: f.subjectA.ID,
		}},
	}
	preview, err := svc.PreviewMerge(base)
	if err != nil {
		t.Fatalf("预览失败: %v", err)
	}

	input := base
	input.CourseMerges = []CourseMergeDecision{{
		LoserSubjectID:     f.subjectB.ID,
		KeeperSubjectID:    f.subjectA.ID,
		MergeSubjectEntity: true,
	}}
	input.SnapshotToken = preview.SnapshotToken
	_, err = svc.Merge(f.admin.ID, input)
	requireStaleToken(t, err)
}

// GOV-03：别名指向的实体被改动，数据快照必须失效（不能只哈希别名文本）。
func TestGovernanceTokenBindsAliasTarget(t *testing.T) {
	f := newGovIntentFixture(t)
	svc := f.service()

	input := MergeInput{KeeperID: f.keeperA.ID, LoserIDs: []uint{f.loserB.ID}}
	first, err := svc.PreviewMerge(input)
	if err != nil {
		t.Fatalf("第一次预览失败: %v", err)
	}

	if err := f.db.Model(&models.TeacherAlias{}).Where("id = ?", f.alias.ID).
		Update("teacher_id", f.keeperA.ID).Error; err != nil {
		t.Fatalf("改别名指向失败: %v", err)
	}

	second, err := svc.PreviewMerge(input)
	if err != nil {
		t.Fatalf("第二次预览失败: %v", err)
	}
	if first.SnapshotToken == second.SnapshotToken {
		t.Fatalf("别名指向实体变化后快照凭证未改变")
	}

	retry := input
	retry.SnapshotToken = first.SnapshotToken
	_, err = svc.Merge(f.admin.ID, retry)
	requireStaleToken(t, err)
}
