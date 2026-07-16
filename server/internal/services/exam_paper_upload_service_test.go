package services

import (
	"errors"
	"fmt"
	"testing"
	"time"

	"github.com/glebarez/sqlite"
	"github.com/google/uuid"
	"github.com/stretchr/testify/require"
	"gorm.io/gorm"

	"shenliyuan/internal/models"
)

var examPaperUploadTestNow = time.Date(2026, 7, 12, 10, 0, 0, 0, time.UTC)

type examPaperUploadTestEnv struct {
	db            *gorm.DB
	grantSigner   *ExamPaperStorageSigner
	receiptSigner *ExamPaperStorageSigner
	service       *ExamPaperUploadService
	attemptedJobs []uint
	attemptErr    error
}

func newExamPaperUploadTestEnv(t *testing.T) *examPaperUploadTestEnv {
	t.Helper()
	db, err := gorm.Open(sqlite.Open(fmt.Sprintf("file:%s?mode=memory&cache=shared", uuid.NewString())), &gorm.Config{TranslateError: true})
	require.NoError(t, err)
	require.NoError(t, db.AutoMigrate(
		&models.User{},
		&models.ExamPaper{},
		&models.ExamPaperUploadSession{},
		&models.ExamPaperStorageJob{},
		&models.AdminLog{},
	))
	require.NoError(t, models.EnsureExamPaperIndexes(db))
	grantSigner, err := NewExamPaperStorageSigner("grant-secret", func() time.Time { return examPaperUploadTestNow })
	require.NoError(t, err)
	receiptSigner, err := NewExamPaperStorageSigner("receipt-secret", func() time.Time { return examPaperUploadTestNow })
	require.NoError(t, err)
	env := &examPaperUploadTestEnv{db: db, grantSigner: grantSigner, receiptSigner: receiptSigner}
	env.service = NewExamPaperUploadService(db, grantSigner, receiptSigner, func() time.Time { return examPaperUploadTestNow }, func(jobID uint) error {
		env.attemptedJobs = append(env.attemptedJobs, jobID)
		return env.attemptErr
	})
	return env
}

func createExamPaperUploadTestUser(t *testing.T, db *gorm.DB, role models.Role) models.User {
	t.Helper()
	user := models.User{
		StudentID: fmt.Sprintf("upload-%s-%s", role, uuid.NewString()), PasswordHash: "test",
		Nickname: "上传测试用户", Role: role, EduBound: true,
	}
	require.NoError(t, db.Create(&user).Error)
	return user
}

func examPaperUploadTestMetadata(t *testing.T) models.ExamPaperMetadata {
	t.Helper()
	metadata, err := models.NormalizeExamPaperMetadata("高等数学", "2025-2026", models.ExamPaperSemesterFirst, models.ExamPaperTypeFinal)
	require.NoError(t, err)
	return metadata
}

func signExamPaperUploadReceipt(t *testing.T, env *examPaperUploadTestEnv, sessionID, fileKey, sha256 string, fileSize int64) string {
	t.Helper()
	token, err := env.receiptSigner.SignReceipt(ExamPaperUploadReceipt{
		SessionID: sessionID, FileKey: fileKey, FileSize: fileSize, SHA256: sha256, IssuedAt: examPaperUploadTestNow.Unix(),
	})
	require.NoError(t, err)
	return token
}

func TestExamPaperUploadSessionCreateSignsScopedTenMinuteGrant(t *testing.T) {
	env := newExamPaperUploadTestEnv(t)
	user := createExamPaperUploadTestUser(t, env.db, models.RoleUser)

	session, token, err := env.service.CreateSession(user, examPaperUploadTestMetadata(t), 4096)
	require.NoError(t, err)
	require.NotEmpty(t, session.ID)
	require.Equal(t, models.ExamPaperUploadOpen, session.Status)
	require.Equal(t, examPaperUploadTestNow.Add(ExamPaperUploadSessionTTL), session.ExpiresAt)

	path := "/v1/uploads/" + session.ID
	grant, err := env.grantSigner.VerifyGrant(token, ExamPaperStoragePurposeUpload, "POST", path)
	require.NoError(t, err)
	require.Equal(t, session.ID, grant.SessionID)
	require.Equal(t, user.ID, grant.UserID)
	require.Equal(t, int64(4096), grant.ExpectedSize)
	require.Equal(t, examPaperUploadTestNow.Unix(), grant.IssuedAt)
	require.Equal(t, session.ExpiresAt.Unix(), grant.ExpiresAt)
	require.NotEmpty(t, grant.JTI)
}

func TestExamPaperUploadReceiptCompletesUserSubmissionAndSchedulesClaim(t *testing.T) {
	env := newExamPaperUploadTestEnv(t)
	env.attemptErr = errors.New("任务执行器暂未配置")
	user := createExamPaperUploadTestUser(t, env.db, models.RoleUser)
	session, _, err := env.service.CreateSession(user, examPaperUploadTestMetadata(t), 4096)
	require.NoError(t, err)
	receipt := signExamPaperUploadReceipt(t, env, session.ID, "11111111-1111-4111-8111-111111111111.pdf", "1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef", 4096)

	paper, err := env.service.CompleteSession(user.ID, session.ID, receipt)
	require.NoError(t, err)
	require.Equal(t, models.ExamPaperStatusPending, paper.Status)
	require.Equal(t, models.ExamPaperSourceUser, paper.Source)
	require.Equal(t, models.ExamPaperStorageRemote, paper.StorageBackend)
	require.Equal(t, "11111111-1111-4111-8111-111111111111.pdf", paper.FileKey)
	require.Nil(t, paper.RewardedAt)

	var reloadedSession models.ExamPaperUploadSession
	require.NoError(t, env.db.First(&reloadedSession, "id = ?", session.ID).Error)
	require.Equal(t, models.ExamPaperUploadCompleted, reloadedSession.Status)
	require.NotNil(t, reloadedSession.CompletedAt)
	require.Equal(t, paper.FileKey, reloadedSession.StorageKey)

	var job models.ExamPaperStorageJob
	require.NoError(t, env.db.First(&job).Error)
	require.Equal(t, "claim", job.Operation)
	require.Equal(t, models.ExamPaperStorageRemote, job.StorageBackend)
	require.Equal(t, paper.FileKey, job.FileKey)
	require.Nil(t, job.CompletedAt)
	require.False(t, job.NextAttemptAt.After(examPaperUploadTestNow))
	require.Equal(t, []uint{job.ID}, env.attemptedJobs)
}

func TestExamPaperUploadReceiptCompletesAdminSubmissionAsPublished(t *testing.T) {
	env := newExamPaperUploadTestEnv(t)
	admin := createExamPaperUploadTestUser(t, env.db, models.RoleAdmin)
	session, _, err := env.service.CreateSession(admin, examPaperUploadTestMetadata(t), 2048)
	require.NoError(t, err)
	receipt := signExamPaperUploadReceipt(t, env, session.ID, "22222222-2222-4222-8222-222222222222.pdf", "2234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef", 2048)

	paper, err := env.service.CompleteSession(admin.ID, session.ID, receipt)
	require.NoError(t, err)
	require.Equal(t, models.ExamPaperStatusPublished, paper.Status)
	require.Equal(t, models.ExamPaperSourceAdmin, paper.Source)
	require.Equal(t, &admin.ID, paper.ReviewerID)
	require.NotNil(t, paper.PublishedAt)
	require.Nil(t, paper.RewardedAt)

	var logs []models.AdminLog
	require.NoError(t, env.db.Find(&logs).Error)
	require.Len(t, logs, 1)
	require.Equal(t, admin.ID, logs[0].AdminID)
	require.Contains(t, logs[0].Detail, "不发放经验")
}

func TestExamPaperUploadReceiptRejectsWhenPendingQuotaReached(t *testing.T) {
	env := newExamPaperUploadTestEnv(t)
	user := createExamPaperUploadTestUser(t, env.db, models.RoleUser)
	for index := 0; index < ExamPaperMaxPendingSubmissionsPerUser; index++ {
		require.NoError(t, env.db.Create(&models.ExamPaper{
			Status: models.ExamPaperStatusPending, Source: models.ExamPaperSourceUser, SubmitterID: user.ID,
			CourseName: fmt.Sprintf("配额-%d", index), AcademicYear: "2025-2026", Semester: models.ExamPaperSemesterFirst,
			ExamType: models.ExamPaperTypeFinal, Title: fmt.Sprintf("配额-%d", index), FileKey: fmt.Sprintf("quota-%d.pdf", index),
			FileSize: 1, SHA256: fmt.Sprintf("quota-sha-%d", index),
		}).Error)
	}
	session, _, err := env.service.CreateSession(user, examPaperUploadTestMetadata(t), 1024)
	require.NoError(t, err)
	receipt := signExamPaperUploadReceipt(t, env, session.ID, "12121212-1212-4212-8212-121212121212.pdf", "1134567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef", 1024)

	_, err = env.service.CompleteSession(user.ID, session.ID, receipt)
	require.ErrorIs(t, err, ErrExamPaperUploadQuotaExceeded)
	var reloaded models.ExamPaperUploadSession
	require.NoError(t, env.db.First(&reloaded, "id = ?", session.ID).Error)
	require.Equal(t, models.ExamPaperUploadOpen, reloaded.Status)
	var paperCount, jobCount int64
	require.NoError(t, env.db.Model(&models.ExamPaper{}).Count(&paperCount).Error)
	require.NoError(t, env.db.Model(&models.ExamPaperStorageJob{}).Count(&jobCount).Error)
	require.EqualValues(t, ExamPaperMaxPendingSubmissionsPerUser, paperCount)
	require.Zero(t, jobCount)
	require.Empty(t, env.attemptedJobs)
}

func TestExamPaperUploadReceiptSequentialCompletionsRespectPendingQuota(t *testing.T) {
	env := newExamPaperUploadTestEnv(t)
	user := createExamPaperUploadTestUser(t, env.db, models.RoleUser)
	for index := 0; index < ExamPaperMaxPendingSubmissionsPerUser-1; index++ {
		require.NoError(t, env.db.Create(&models.ExamPaper{
			Status: models.ExamPaperStatusPending, Source: models.ExamPaperSourceUser, SubmitterID: user.ID,
			CourseName: fmt.Sprintf("顺序-%d", index), AcademicYear: "2025-2026", Semester: models.ExamPaperSemesterFirst,
			ExamType: models.ExamPaperTypeFinal, Title: fmt.Sprintf("顺序-%d", index), FileKey: fmt.Sprintf("sequential-%d.pdf", index),
			FileSize: 1, SHA256: fmt.Sprintf("sequential-sha-%d", index),
		}).Error)
	}
	firstSession, _, err := env.service.CreateSession(user, examPaperUploadTestMetadata(t), 1024)
	require.NoError(t, err)
	secondSession, _, err := env.service.CreateSession(user, examPaperUploadTestMetadata(t), 1024)
	require.NoError(t, err)
	firstReceipt := signExamPaperUploadReceipt(t, env, firstSession.ID, "13131313-1313-4313-8313-131313131313.pdf", "1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef", 1024)
	secondReceipt := signExamPaperUploadReceipt(t, env, secondSession.ID, "14141414-1414-4414-8414-141414141414.pdf", "2234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef", 1024)

	_, err = env.service.CompleteSession(user.ID, firstSession.ID, firstReceipt)
	require.NoError(t, err)
	_, err = env.service.CompleteSession(user.ID, secondSession.ID, secondReceipt)
	require.ErrorIs(t, err, ErrExamPaperUploadQuotaExceeded)
	var pendingCount, jobCount int64
	require.NoError(t, env.db.Model(&models.ExamPaper{}).Where("submitter_id = ? AND status = ?", user.ID, models.ExamPaperStatusPending).Count(&pendingCount).Error)
	require.NoError(t, env.db.Model(&models.ExamPaperStorageJob{}).Count(&jobCount).Error)
	require.EqualValues(t, ExamPaperMaxPendingSubmissionsPerUser, pendingCount)
	require.EqualValues(t, 1, jobCount)
	require.Len(t, env.attemptedJobs, 1)
	var secondReloaded models.ExamPaperUploadSession
	require.NoError(t, env.db.First(&secondReloaded, "id = ?", secondSession.ID).Error)
	require.Equal(t, models.ExamPaperUploadOpen, secondReloaded.Status)
}

func TestExamPaperUploadReceiptAdminIgnoresPendingQuota(t *testing.T) {
	env := newExamPaperUploadTestEnv(t)
	admin := createExamPaperUploadTestUser(t, env.db, models.RoleAdmin)
	for index := 0; index < ExamPaperMaxPendingSubmissionsPerUser; index++ {
		require.NoError(t, env.db.Create(&models.ExamPaper{
			Status: models.ExamPaperStatusPending, Source: models.ExamPaperSourceUser, SubmitterID: admin.ID,
			CourseName: fmt.Sprintf("管理员配额-%d", index), AcademicYear: "2025-2026", Semester: models.ExamPaperSemesterFirst,
			ExamType: models.ExamPaperTypeFinal, Title: fmt.Sprintf("管理员配额-%d", index), FileKey: fmt.Sprintf("admin-quota-%d.pdf", index),
			FileSize: 1, SHA256: fmt.Sprintf("admin-quota-sha-%d", index),
		}).Error)
	}
	session, _, err := env.service.CreateSession(admin, examPaperUploadTestMetadata(t), 1024)
	require.NoError(t, err)
	receipt := signExamPaperUploadReceipt(t, env, session.ID, "15151515-1515-4515-8515-151515151515.pdf", "3234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef", 1024)

	paper, err := env.service.CompleteSession(admin.ID, session.ID, receipt)
	require.NoError(t, err)
	require.Equal(t, models.ExamPaperStatusPublished, paper.Status)
}

func TestExamPaperUploadReceiptRepeatedCompletionIsIdempotent(t *testing.T) {
	env := newExamPaperUploadTestEnv(t)
	admin := createExamPaperUploadTestUser(t, env.db, models.RoleSuperAdmin)
	session, _, err := env.service.CreateSession(admin, examPaperUploadTestMetadata(t), 1024)
	require.NoError(t, err)
	receipt := signExamPaperUploadReceipt(t, env, session.ID, "33333333-3333-4333-8333-333333333333.pdf", "3234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef", 1024)

	first, err := env.service.CompleteSession(admin.ID, session.ID, receipt)
	require.NoError(t, err)
	second, err := env.service.CompleteSession(admin.ID, session.ID, receipt)
	require.NoError(t, err)
	require.Equal(t, first.ID, second.ID)
	require.Equal(t, []uint{1}, env.attemptedJobs)

	var paperCount, jobCount, logCount int64
	require.NoError(t, env.db.Model(&models.ExamPaper{}).Count(&paperCount).Error)
	require.NoError(t, env.db.Model(&models.ExamPaperStorageJob{}).Count(&jobCount).Error)
	require.NoError(t, env.db.Model(&models.AdminLog{}).Count(&logCount).Error)
	require.EqualValues(t, 1, paperCount)
	require.EqualValues(t, 1, jobCount)
	require.EqualValues(t, 1, logCount)
}

func TestExamPaperUploadReceiptDuplicateSHAKeepsSessionOpenWithoutJob(t *testing.T) {
	env := newExamPaperUploadTestEnv(t)
	user := createExamPaperUploadTestUser(t, env.db, models.RoleUser)
	const duplicateSHA = "4234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef"
	require.NoError(t, env.db.Create(&models.ExamPaper{
		Status: models.ExamPaperStatusPublished, Source: models.ExamPaperSourceUser, SubmitterID: user.ID,
		CourseName: "已有试卷", AcademicYear: "2025-2026", Semester: models.ExamPaperSemesterFirst,
		ExamType: models.ExamPaperTypeFinal, Title: "已有试卷", FileKey: "claimed/existing.pdf", FileSize: 512, SHA256: duplicateSHA,
	}).Error)
	session, _, err := env.service.CreateSession(user, examPaperUploadTestMetadata(t), 512)
	require.NoError(t, err)
	receipt := signExamPaperUploadReceipt(t, env, session.ID, "44444444-4444-4444-8444-444444444444.pdf", duplicateSHA, 512)

	_, err = env.service.CompleteSession(user.ID, session.ID, receipt)
	require.ErrorIs(t, err, ErrExamPaperUploadDuplicate)
	var reloaded models.ExamPaperUploadSession
	require.NoError(t, env.db.First(&reloaded, "id = ?", session.ID).Error)
	require.Equal(t, models.ExamPaperUploadOpen, reloaded.Status)
	require.Empty(t, reloaded.StorageKey)
	var jobCount int64
	require.NoError(t, env.db.Model(&models.ExamPaperStorageJob{}).Count(&jobCount).Error)
	require.Zero(t, jobCount)
	require.Empty(t, env.attemptedJobs)
}

func TestExamPaperUploadReceiptRejectsUnreasonableIssuedAt(t *testing.T) {
	env := newExamPaperUploadTestEnv(t)
	user := createExamPaperUploadTestUser(t, env.db, models.RoleUser)
	session, _, err := env.service.CreateSession(user, examPaperUploadTestMetadata(t), 1024)
	require.NoError(t, err)
	token, err := env.receiptSigner.SignReceipt(ExamPaperUploadReceipt{
		SessionID: session.ID, FileKey: "55555555-5555-4555-8555-555555555555.pdf", FileSize: 1024,
		SHA256:   "5234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef",
		IssuedAt: examPaperUploadTestNow.Add(time.Hour).Unix(),
	})
	require.NoError(t, err)

	_, err = env.service.CompleteSession(user.ID, session.ID, token)
	require.ErrorIs(t, err, ErrExamPaperUploadReceiptInvalid)
}

func TestExamPaperUploadReceiptRejectsUnsafeFileKey(t *testing.T) {
	env := newExamPaperUploadTestEnv(t)
	user := createExamPaperUploadTestUser(t, env.db, models.RoleUser)
	session, _, err := env.service.CreateSession(user, examPaperUploadTestMetadata(t), 1024)
	require.NoError(t, err)
	receipt := signExamPaperUploadReceipt(t, env, session.ID, "../claimed/escape.pdf", "6234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef", 1024)

	_, err = env.service.CompleteSession(user.ID, session.ID, receipt)
	require.ErrorIs(t, err, ErrExamPaperUploadReceiptInvalid)
}

func TestExamPaperUploadSessionRejectsInvalidExpectedSize(t *testing.T) {
	env := newExamPaperUploadTestEnv(t)
	user := createExamPaperUploadTestUser(t, env.db, models.RoleUser)
	for _, size := range []int64{0, -1, ExamPaperMaxFileSize + 1} {
		_, _, err := env.service.CreateSession(user, examPaperUploadTestMetadata(t), size)
		require.ErrorIs(t, err, ErrExamPaperUploadSizeInvalid)
	}
	var count int64
	require.NoError(t, env.db.Model(&models.ExamPaperUploadSession{}).Count(&count).Error)
	require.Zero(t, count)
}

func TestExamPaperUploadSessionDoesNotPersistWhenGrantSigningFails(t *testing.T) {
	env := newExamPaperUploadTestEnv(t)
	user := createExamPaperUploadTestUser(t, env.db, models.RoleUser)
	env.service.grantSigner = nil

	_, _, err := env.service.CreateSession(user, examPaperUploadTestMetadata(t), 1024)
	require.ErrorIs(t, err, ErrStorageSecretRequired)
	var count int64
	require.NoError(t, env.db.Model(&models.ExamPaperUploadSession{}).Count(&count).Error)
	require.Zero(t, count)
}

func TestExamPaperUploadRepeatedCompletionCannotReturnAnotherUsersPaper(t *testing.T) {
	env := newExamPaperUploadTestEnv(t)
	owner := createExamPaperUploadTestUser(t, env.db, models.RoleUser)
	other := createExamPaperUploadTestUser(t, env.db, models.RoleUser)
	session, _, err := env.service.CreateSession(owner, examPaperUploadTestMetadata(t), 1024)
	require.NoError(t, err)
	const fileKey = "dddddddd-dddd-4ddd-8ddd-dddddddddddd.pdf"
	require.NoError(t, env.db.Create(&models.ExamPaper{
		Status: models.ExamPaperStatusPending, Source: models.ExamPaperSourceUser, SubmitterID: other.ID,
		StorageBackend: models.ExamPaperStorageRemote, CourseName: "其他试卷", AcademicYear: "2025-2026",
		Semester: models.ExamPaperSemesterFirst, ExamType: models.ExamPaperTypeFinal, Title: "其他试卷",
		FileKey: fileKey, FileSize: 1024, SHA256: "d234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef",
	}).Error)
	completedAt := examPaperUploadTestNow
	require.NoError(t, env.db.Model(session).Updates(map[string]any{
		"status": models.ExamPaperUploadCompleted, "storage_key": fileKey, "file_size": 1024,
		"sha256": "d234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef", "completed_at": completedAt,
	}).Error)

	_, err = env.service.CompleteSession(owner.ID, session.ID, "unused-after-completion")
	require.ErrorIs(t, err, ErrExamPaperUploadSessionInconsistent)
}

func TestExamPaperUploadReceiptRejectsInvalidSessionAndReceiptInputs(t *testing.T) {
	tests := []struct {
		name    string
		prepare func(t *testing.T, env *examPaperUploadTestEnv, owner, other models.User, session *models.ExamPaperUploadSession) (uint, string)
		wantErr error
	}{
		{
			name: "空回执", wantErr: ErrExamPaperUploadReceiptInvalid,
			prepare: func(_ *testing.T, _ *examPaperUploadTestEnv, owner, _ models.User, _ *models.ExamPaperUploadSession) (uint, string) {
				return owner.ID, ""
			},
		},
		{
			name: "畸形回执", wantErr: ErrExamPaperUploadReceiptInvalid,
			prepare: func(_ *testing.T, _ *examPaperUploadTestEnv, owner, _ models.User, _ *models.ExamPaperUploadSession) (uint, string) {
				return owner.ID, "not-a-token"
			},
		},
		{
			name: "伪造密钥", wantErr: ErrExamPaperUploadReceiptInvalid,
			prepare: func(t *testing.T, _ *examPaperUploadTestEnv, owner, _ models.User, session *models.ExamPaperUploadSession) (uint, string) {
				wrongSigner, err := NewExamPaperStorageSigner("wrong-secret", func() time.Time { return examPaperUploadTestNow })
				require.NoError(t, err)
				token, err := wrongSigner.SignReceipt(ExamPaperUploadReceipt{SessionID: session.ID, FileKey: "77777777-7777-4777-8777-777777777777.pdf", FileSize: 1024, SHA256: "7234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef", IssuedAt: examPaperUploadTestNow.Unix()})
				require.NoError(t, err)
				return owner.ID, token
			},
		},
		{
			name: "回执会话不匹配", wantErr: ErrExamPaperUploadReceiptInvalid,
			prepare: func(t *testing.T, env *examPaperUploadTestEnv, owner, _ models.User, _ *models.ExamPaperUploadSession) (uint, string) {
				return owner.ID, signExamPaperUploadReceipt(t, env, "other-session", "88888888-8888-4888-8888-888888888888.pdf", "8234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef", 1024)
			},
		},
		{
			name: "文件大小不匹配", wantErr: ErrExamPaperUploadReceiptInvalid,
			prepare: func(t *testing.T, env *examPaperUploadTestEnv, owner, _ models.User, session *models.ExamPaperUploadSession) (uint, string) {
				return owner.ID, signExamPaperUploadReceipt(t, env, session.ID, "99999999-9999-4999-8999-999999999999.pdf", "9234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef", 512)
			},
		},
		{
			name: "他人会话", wantErr: ErrExamPaperUploadSessionNotFound,
			prepare: func(t *testing.T, env *examPaperUploadTestEnv, _ models.User, other models.User, session *models.ExamPaperUploadSession) (uint, string) {
				return other.ID, signExamPaperUploadReceipt(t, env, session.ID, "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa.pdf", "a234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef", 1024)
			},
		},
		{
			name: "过期会话", wantErr: ErrExamPaperUploadSessionExpired,
			prepare: func(t *testing.T, env *examPaperUploadTestEnv, owner, _ models.User, session *models.ExamPaperUploadSession) (uint, string) {
				require.NoError(t, env.db.Model(session).Update("expires_at", examPaperUploadTestNow.Add(-time.Second)).Error)
				return owner.ID, signExamPaperUploadReceipt(t, env, session.ID, "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb.pdf", "b234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef", 1024)
			},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			env := newExamPaperUploadTestEnv(t)
			owner := createExamPaperUploadTestUser(t, env.db, models.RoleUser)
			other := createExamPaperUploadTestUser(t, env.db, models.RoleUser)
			session, _, err := env.service.CreateSession(owner, examPaperUploadTestMetadata(t), 1024)
			require.NoError(t, err)
			userID, receipt := tt.prepare(t, env, owner, other, session)

			_, err = env.service.CompleteSession(userID, session.ID, receipt)
			require.ErrorIs(t, err, tt.wantErr)
			var reloaded models.ExamPaperUploadSession
			require.NoError(t, env.db.First(&reloaded, "id = ?", session.ID).Error)
			require.Equal(t, models.ExamPaperUploadOpen, reloaded.Status)
			var paperCount, jobCount int64
			require.NoError(t, env.db.Model(&models.ExamPaper{}).Count(&paperCount).Error)
			require.NoError(t, env.db.Model(&models.ExamPaperStorageJob{}).Count(&jobCount).Error)
			require.Zero(t, paperCount)
			require.Zero(t, jobCount)
		})
	}
}

func TestExamPaperUploadReceiptRollsBackWhenJobCreationFails(t *testing.T) {
	env := newExamPaperUploadTestEnv(t)
	user := createExamPaperUploadTestUser(t, env.db, models.RoleUser)
	session, _, err := env.service.CreateSession(user, examPaperUploadTestMetadata(t), 1024)
	require.NoError(t, err)
	receipt := signExamPaperUploadReceipt(t, env, session.ID, "cccccccc-cccc-4ccc-8ccc-cccccccccccc.pdf", "c234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef", 1024)
	injectedErr := errors.New("注入存储任务创建失败")
	require.NoError(t, env.db.Callback().Create().Before("gorm:create").Register("test:fail-storage-job", func(tx *gorm.DB) {
		if tx.Statement.Schema != nil && tx.Statement.Schema.Name == "ExamPaperStorageJob" {
			tx.AddError(injectedErr)
		}
	}))

	_, err = env.service.CompleteSession(user.ID, session.ID, receipt)
	require.ErrorIs(t, err, injectedErr)
	var reloaded models.ExamPaperUploadSession
	require.NoError(t, env.db.First(&reloaded, "id = ?", session.ID).Error)
	require.Equal(t, models.ExamPaperUploadOpen, reloaded.Status)
	require.Empty(t, reloaded.StorageKey)
	var paperCount, jobCount int64
	require.NoError(t, env.db.Model(&models.ExamPaper{}).Count(&paperCount).Error)
	require.NoError(t, env.db.Model(&models.ExamPaperStorageJob{}).Count(&jobCount).Error)
	require.Zero(t, paperCount)
	require.Zero(t, jobCount)
	require.Empty(t, env.attemptedJobs)
}

func TestExamPaperUploadReceiptAttemptPanicDoesNotEscapeCommittedTransaction(t *testing.T) {
	env := newExamPaperUploadTestEnv(t)
	env.service.attempt = func(uint) error { panic("注入任务尝试 panic") }
	user := createExamPaperUploadTestUser(t, env.db, models.RoleUser)
	session, _, err := env.service.CreateSession(user, examPaperUploadTestMetadata(t), 1024)
	require.NoError(t, err)
	receipt := signExamPaperUploadReceipt(t, env, session.ID, "16161616-1616-4616-8616-161616161616.pdf", "4234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef", 1024)

	require.NotPanics(t, func() {
		paper, completeErr := env.service.CompleteSession(user.ID, session.ID, receipt)
		require.NoError(t, completeErr)
		require.NotZero(t, paper.ID)
	})
	var job models.ExamPaperStorageJob
	require.NoError(t, env.db.First(&job).Error)
	require.Nil(t, job.CompletedAt)
	require.False(t, job.NextAttemptAt.After(examPaperUploadTestNow))
}
