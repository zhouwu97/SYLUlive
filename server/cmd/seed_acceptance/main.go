package main

import (
	"bytes"
	"context"
	"crypto/sha256"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/stdlib"
	"golang.org/x/crypto/bcrypt"
	"gorm.io/driver/postgres"
	"gorm.io/gorm"
	"gorm.io/gorm/logger"

	"shenliyuan/internal/models"
)

func acceptanceConfig(dsn string) (*pgx.ConnConfig, error) {
	if strings.TrimSpace(dsn) == "" {
		return nil, fmt.Errorf("DSN is required")
	}
	settings, err := pgx.ParseConfig(dsn)
	if err != nil || !strings.HasSuffix(settings.Database, "_acceptance") {
		return nil, fmt.Errorf("DSN must name an _acceptance database")
	}
	local := func(host string) bool { return host == "127.0.0.1" || host == "localhost" || host == "::1" }
	if !local(settings.Host) {
		return nil, fmt.Errorf("DSN must use a loopback host")
	}
	for _, fallback := range settings.Fallbacks {
		if !local(fallback.Host) {
			return nil, fmt.Errorf("DSN fallback must use a loopback host")
		}
	}
	settings.LookupFunc = func(_ context.Context, host string) ([]string, error) {
		if host == "localhost" {
			return []string{"127.0.0.1", "::1"}, nil
		}
		return []string{host}, nil
	}
	return settings, nil
}

func main() {
	settings, err := acceptanceConfig(os.Getenv("DSN"))
	if err != nil {
		log.Fatal(err)
	}
	connection := stdlib.OpenDB(*settings)
	defer connection.Close()
	db, err := gorm.Open(postgres.New(postgres.Config{Conn: connection}), &gorm.Config{Logger: logger.Default.LogMode(logger.Silent)})
	if err != nil {
		log.Fatal("acceptance database connection failed")
	}
	if err := db.Transaction(seed); err != nil {
		log.Fatal(err)
	}
	fmt.Println("Acceptance users, content and review fixtures are ready.")
}

func seed(db *gorm.DB) error {
	var superAdmin models.User
	if err := db.First(&superAdmin, "student_id = ? AND role = ?", os.Getenv("SUPER_ADMIN_ID"), models.RoleSuperAdmin).Error; err != nil {
		return fmt.Errorf("S1 is missing; start the acceptance server first: %w", err)
	}
	now := time.Now()
	users := map[string]models.User{"S1": superAdmin}
	for _, label := range []string{"U1", "U2", "U3", "M1", "A1"} {
		studentID, password := os.Getenv(label+"_ID"), os.Getenv(label+"_PASSWORD")
		if studentID == "" || password == "" {
			return fmt.Errorf("%s_ID and %s_PASSWORD are required", label, label)
		}
		role, status := models.RoleUser, "active"
		if label == "A1" {
			role = models.RoleAdmin
		}
		if label == "U3" {
			status = "banned"
		}
		var user models.User
		query := db.Where("student_id = ?", studentID)
		if err := query.First(&user).Error; err == gorm.ErrRecordNotFound {
			hash, err := bcrypt.GenerateFromPassword([]byte(password), bcrypt.DefaultCost)
			if err != nil {
				return fmt.Errorf("%s password: %w", label, err)
			}
			user = models.User{StudentID: studentID, StudentVerifiedAt: &now, Nickname: "Acceptance " + label, PasswordHash: string(hash), Role: role, AccountStatus: status}
			if err := db.Create(&user).Error; err != nil {
				return fmt.Errorf("create %s: %w", label, err)
			}
		} else if err != nil {
			return fmt.Errorf("read %s: %w", label, err)
		}
		if user.Nickname != "Acceptance "+label {
			return fmt.Errorf("%s ID belongs to another fixture or an existing account", label)
		}
		users[label] = user
	}
	for _, account := range users {
		alias := models.AccountLoginAlias{UserID: account.ID, Value: account.StudentID, Source: "acceptance_fixture"}
		if err := fixture(db, &alias, map[string]any{"user_id": account.ID, "value": account.StudentID}); err != nil {
			return err
		}
	}
	return seedContent(db, users, now)
}

func fixture(db *gorm.DB, record any, key any) error {
	if err := db.Where(key).Attrs(record).FirstOrCreate(record).Error; err != nil {
		return fmt.Errorf("seed %T: %w", record, err)
	}
	return nil
}

func paperFixture(index int) ([]byte, string) {
	var pdf bytes.Buffer
	stream := fmt.Sprintf("BT /F1 16 Tf 30 100 Td (Acceptance paper %d) Tj ET\n", index)
	objects := []string{
		"<< /Type /Catalog /Pages 2 0 R >>",
		"<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
		"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 250 150] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>",
		fmt.Sprintf("<< /Length %d >>\nstream\n%sendstream", len(stream), stream),
		"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
	}
	fmt.Fprintln(&pdf, "%PDF-1.4")
	offsets := make([]int, 0, len(objects))
	for position, object := range objects {
		offsets = append(offsets, pdf.Len())
		fmt.Fprintf(&pdf, "%d 0 obj\n%s\nendobj\n", position+1, object)
	}
	xref := pdf.Len()
	fmt.Fprintf(&pdf, "xref\n0 %d\n0000000000 65535 f \n", len(objects)+1)
	for _, offset := range offsets {
		fmt.Fprintf(&pdf, "%010d 00000 n \n", offset)
	}
	fmt.Fprintf(&pdf, "trailer\n<< /Size %d /Root 1 0 R >>\nstartxref\n%d\n%%%%EOF\n", len(objects)+1, xref)
	return pdf.Bytes(), fmt.Sprintf("%x", sha256.Sum256(pdf.Bytes()))
}

func seedContent(db *gorm.DB, users map[string]models.User, now time.Time) error {
	author, other, moderator, admin := users["U1"].ID, users["U2"].ID, users["M1"].ID, users["A1"].ID
	var section models.WaterSection
	if err := db.First(&section, "slug = ?", "campus_life").Error; err != nil {
		return err
	}
	assignment := models.WaterSectionModerator{SectionID: section.ID, UserID: moderator, AssignedBy: admin, Role: "moderator", Status: models.ModeratorStatusActive, CanEditSection: true, CanManageTags: true, CanPinPost: true, CanDeletePost: true, CanMuteUser: true}
	if err := fixture(db, &assignment, map[string]any{"section_id": section.ID, "user_id": moderator}); err != nil {
		return err
	}
	teamTag := models.WaterSectionTag{SectionID: section.ID, Slug: "team", Name: "Acceptance team", ContentMode: models.WaterTagModeTeamRecruitment}
	if err := fixture(db, &teamTag, map[string]any{"section_id": section.ID, "content_mode": models.WaterTagModeTeamRecruitment}); err != nil {
		return err
	}
	var category models.CompetitionCategory
	if err := db.First(&category).Error; err != nil {
		return err
	}
	for index := 1; index <= 2; index++ {
		label := fmt.Sprintf("Acceptance %d", index)
		verified := index == 1
		post := models.Post{Title: label + " post", Content: "Local acceptance post", AuthorID: author, BoardID: models.BoardShuitie, PostType: section.Slug, ReplyCount: 1}
		pollPost := models.Post{Title: label + " poll", Content: "Local acceptance poll", AuthorID: author, BoardID: models.BoardShuitie, PostType: section.Slug, ContentKind: models.PostContentKindPoll}
		teamPost := models.Post{Title: label + " team", Content: "Local acceptance recruitment", AuthorID: other, BoardID: models.BoardShuitie, PostType: section.Slug, WaterTagID: &teamTag.ID}
		for _, item := range []*models.Post{&post, &pollPost, &teamPost} {
			if err := fixture(db, item, map[string]any{"title": item.Title, "author_id": item.AuthorID}); err != nil {
				return err
			}
		}
		canteen := models.Canteen{Name: label + " canteen", NormalizedName: strings.ToLower(label + " canteen"), LocationArea: "other", Verified: verified, CreatedBy: author}
		course := models.CourseSubject{Name: label + " course", NormalizedName: models.NormalizeCourseSubjectName(label + " course"), Verified: verified, CreatedBy: &author}
		poll := models.Poll{PostID: pollPost.ID, Category: models.PollCategoryCampusLife, SelectionMode: models.PollSelectionSingle, MaxChoices: 1, ResultsVisibility: models.PollResultsAlways, Status: models.PollStatusActive, EndsAt: now.AddDate(0, 1, 0)}
		team := models.WaterTeamRecruitment{PostID: teamPost.ID, SectionID: section.ID, TagID: teamTag.ID, Category: models.TeamCategoryStudy, NeededCount: 3, RolesJSON: `[]`, Status: models.RecruitmentStatusRecruiting}
		if err := fixture(db, &canteen, map[string]any{"name": canteen.Name, "created_by": author}); err != nil {
			return err
		}
		if err := fixture(db, &course, map[string]any{"normalized_name": course.NormalizedName}); err != nil {
			return err
		}
		if err := fixture(db, &poll, map[string]any{"post_id": poll.PostID}); err != nil {
			return err
		}
		if err := fixture(db, &team, map[string]any{"post_id": team.PostID}); err != nil {
			return err
		}
		paper := models.ExamPaper{Title: label + " exam", CourseName: course.Name, AcademicYear: "2026-2027", Semester: models.ExamPaperSemesterFirst, ExamType: models.ExamPaperTypeFinal, Source: models.ExamPaperSourceUser, Status: models.ExamPaperStatusPending, SubmitterID: author, FileKey: fmt.Sprintf("acceptance-%d.pdf", index)}
		pdf, digest := paperFixture(index)
		paper.FileSize, paper.SHA256 = int64(len(pdf)), digest
		if verified {
			paper.Status, paper.PublishedAt = models.ExamPaperStatusPublished, &now
		}
		for _, entry := range []struct {
			record any
			key    map[string]any
		}{
			{&models.Reply{PostID: post.ID, AuthorID: other, Content: label + " reply"}, map[string]any{"post_id": post.ID, "author_id": other, "content": label + " reply"}},
			{&models.CanteenDish{CanteenID: canteen.ID, Name: label + " dish", NormalizedName: strings.ToLower(label + " dish"), Status: models.DishStatusActive, CreatedBy: author}, map[string]any{"canteen_id": canteen.ID, "name": label + " dish"}},
			{&models.Teacher{Name: label + " teacher", NameNormalized: models.NormalizeTeacherName(label + " teacher"), Course: course.Name, CourseSubjectID: &course.ID, Verified: verified, CreatedBy: author}, map[string]any{"name": label + " teacher", "created_by": author}},
			{&models.CompetitionEvent{CompetitionID: fmt.Sprintf("acceptance-%d", index), Title: label + " competition", PrimaryCategoryID: category.ID, Status: "published", IsVerified: true, SearchDisplayAllowed: true, CreatedBy: admin}, map[string]any{"competition_id": fmt.Sprintf("acceptance-%d", index)}},
			{&paper, map[string]any{"title": paper.Title, "submitter_id": author}},
			{&models.PollOption{PollID: poll.ID, Text: "Option A", SortOrder: 1}, map[string]any{"poll_id": poll.ID, "sort_order": 1}},
			{&models.PollOption{PollID: poll.ID, Text: "Option B", SortOrder: 2}, map[string]any{"poll_id": poll.ID, "sort_order": 2}},
			{&models.Announcement{Title: label + " announcement", Content: "Local acceptance announcement", CreatedBy: admin, Status: "published", IncludeNewUsers: true}, map[string]any{"title": label + " announcement", "created_by": admin}},
		} {
			if err := fixture(db, entry.record, entry.key); err != nil {
				return err
			}
		}
		if paper.SHA256 == digest && paper.FileKey == fmt.Sprintf("acceptance-%d.pdf", index) {
			path := filepath.Join("..", "docs", "reports", "launch-acceptance", "exam-papers", paper.FileKey)
			if err := os.WriteFile(path, pdf, 0o600); err != nil {
				return err
			}
		}
		if !verified {
			if err := seedReviews(db, section.ID, post.ID, team.ID, teamPost.ID, author, other, moderator, admin); err != nil {
				return err
			}
		}
	}
	return nil
}

func seedReviews(db *gorm.DB, section, post, team, teamPost, author, other, moderator, admin uint) error {
	const label = "Acceptance review"
	report := models.Report{ReporterID: other, TargetType: "post", TargetID: post, TargetAuthorID: &author, Reason: label, TargetSnapshot: "{}"}
	if err := fixture(db, &report, map[string]any{"reporter_id": other, "target_type": "post", "target_id": post}); err != nil {
		return err
	}
	for _, entry := range []struct {
		record any
		key    map[string]any
	}{
		{&models.Major{Name: label + " major", Level: "undergraduate", CreatedBy: author}, map[string]any{"name": label + " major", "created_by": author}},
		{&models.CourseEvaluationSubmission{UserID: author, DedupKey: "acceptance-review", Source: "manual", Status: models.CourseEvaluationStatusPending, CourseName: "Acceptance 2 course", TeacherName: "Acceptance 2 teacher", Star: 4, Comment: label}, map[string]any{"user_id": author, "dedup_key": "acceptance-review"}},
		{&models.ThemePack{ID: "acceptance-theme", FamilyID: "acceptance-theme", AuthorUserID: author, Name: label, Source: "community", Status: models.ThemeStatusPending, IdempotencyKey: "acceptance-theme"}, map[string]any{"id": "acceptance-theme"}},
		{&models.CommunityEmojiPack{ID: "acceptance-emoji", FamilyID: "acceptance-emoji", UserID: author, Name: label, RequestKey: "acceptance-emoji", Status: models.EmojiPackPending}, map[string]any{"id": "acceptance-emoji"}},
		{&models.EmojiCreator{UserID: author, Description: label, Status: models.EmojiCreatorPending}, map[string]any{"user_id": author}},
		{&models.WaterSectionIconReview{SectionID: section, RequestedBy: moderator, NewAvatarURL: "/uploads/acceptance-icon.png", Status: models.SectionIconReviewPending, Reason: label}, map[string]any{"section_id": section, "requested_by": moderator, "reason": label}},
		{&models.FeaturedApplication{PostID: post, ApplicantID: author, Reason: label}, map[string]any{"post_id": post, "applicant_id": author, "reason": label}},
		{&models.PostRectificationReview{PostID: post, ReportID: &report.ID, SubmittedRevision: 1, Status: "pending"}, map[string]any{"post_id": post, "report_id": report.ID}},
		{&models.Appeal{ReportID: &report.ID, TargetType: "post", TargetID: post, PostID: post, AppellantID: author, AdminID: admin, AppellantReason: label, EvidenceSnapshot: "{}", Status: models.AppealStatusReview}, map[string]any{"report_id": report.ID}},
		{&models.WaterTeamApplication{RecruitmentID: team, PostID: teamPost, ApplicantID: author, OwnerID: other, Message: label, Status: models.ApplicationStatusPending}, map[string]any{"recruitment_id": team, "applicant_id": author}},
		{&models.UserCompetitionAward{UserID: author, CompetitionTitle: label, CompetitionYear: 2026, AwardName: "Acceptance award", VerificationStatus: "pending", SkillTags: []byte(`[]`), EvidenceFileIDs: []byte(`[]`)}, map[string]any{"user_id": author, "competition_title": label}},
	} {
		if err := fixture(db, entry.record, entry.key); err != nil {
			return err
		}
	}
	return nil
}
