package main

import (
	"context"
	"errors"
	"log"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"
	_ "time/tzdata"

	"github.com/gin-gonic/gin"
	"golang.org/x/crypto/bcrypt"

	"gorm.io/driver/postgres"

	"gorm.io/gorm"

	"shenliyuan/internal/academiccalendar"
	"shenliyuan/internal/ai"
	"shenliyuan/internal/ai/mcpclient"
	"shenliyuan/internal/clients"

	"shenliyuan/internal/config"

	"shenliyuan/internal/dto"

	"shenliyuan/internal/handlers"

	"shenliyuan/internal/middleware"

	"shenliyuan/internal/models"

	"shenliyuan/internal/services"

	"shenliyuan/internal/tasks"
)

type externalMCPHealthReader interface {
	Healthy() bool
	HealthStatus() mcpclient.ExternalMCPHealthStatus
}

type externalMCPHealthResponse struct {
	Configured      bool   `json:"configured"`
	Healthy         bool   `json:"healthy"`
	ContractVersion string `json:"contract_version,omitempty"`
	Mode            string `json:"mode,omitempty"`
	AvailableTools  int    `json:"available_tools"`
}

func externalMCPHealthPayload(configured bool, client externalMCPHealthReader, registry *ai.ToolRegistry) externalMCPHealthResponse {
	result := externalMCPHealthResponse{Configured: configured}
	if !configured || client == nil || !client.Healthy() {
		return result
	}
	status := client.HealthStatus()
	if !status.Healthy {
		return result
	}
	result.Healthy = true
	result.ContractVersion = status.ContractVersion
	result.Mode = status.Mode
	for _, name := range []string{
		"hy3_decision.explain_competition_candidates",
		"hy3_decision.compare_competitions",
		"hy3_decision.analyze_academic",
		"hy3_decision.plan_student_week",
	} {
		if registry.HasTool(name) {
			result.AvailableTools++
		}
	}
	return result
}

const examPaperStorageJobAttemptTimeout = 15 * time.Second

type examPaperStorageJobAttemptProcessor interface {
	ProcessJob(context.Context, uint) error
}

type gracefulHTTPServer interface {
	ListenAndServe() error
	Shutdown(context.Context) error
}

// newExamPaperStorageJobAttempt 创建上传事务提交后的即时认领回调。
func newExamPaperStorageJobAttempt(processor examPaperStorageJobAttemptProcessor) services.ExamPaperStorageJobAttempt {
	return func(jobID uint) error {
		ctx, cancel := context.WithTimeout(context.Background(), examPaperStorageJobAttemptTimeout)
		defer cancel()
		return processor.ProcessJob(ctx, jobID)
	}
}

func serveUntilShutdown(ctx context.Context, server gracefulHTTPServer, shutdownTimeout time.Duration) error {
	serveErr := make(chan error, 1)
	go func() { serveErr <- server.ListenAndServe() }()
	select {
	case err := <-serveErr:
		if errors.Is(err, http.ErrServerClosed) {
			return nil
		}
		return err
	case <-ctx.Done():
	}

	shutdownCtx, cancel := context.WithTimeout(context.Background(), shutdownTimeout)
	defer cancel()
	shutdownErr := server.Shutdown(shutdownCtx)
	select {
	case err := <-serveErr:
		if shutdownErr != nil {
			return shutdownErr
		}
		if err != nil && !errors.Is(err, http.ErrServerClosed) {
			return err
		}
		return nil
	case <-shutdownCtx.Done():
		if shutdownErr != nil {
			return shutdownErr
		}
		return shutdownCtx.Err()
	}
}

func main() {
	if err := academiccalendar.InitializeTimezone(); err != nil {
		log.Printf("[ACADEMIC_CALENDAR_TIMEZONE_UNAVAILABLE] %v", err)
	}

	cfg := config.Load()
	middleware.SetLegalConsentEnforcement(cfg.LegalConsentEnforcement)
	appCtx, stopApp := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stopApp()

	// 确保上传目录存在

	os.MkdirAll(cfg.UploadDir, 0755)
	if err := os.MkdirAll(cfg.CompetitionAwardEvidenceDir, 0o700); err != nil {
		log.Fatal("创建竞赛证明材料私有目录失败:", err)
	}

	// 确保 APK 发布根目录与 .tmp 已就绪，避免后续上传 Handler 在缺目录时报错。
	os.MkdirAll(filepath.Join(cfg.AppReleaseDir, "android", "stable", ".tmp"), 0755)

	var db *gorm.DB

	var err error

	if strings.TrimSpace(cfg.DSN) == "" {
		log.Fatal("DATABASE_DSN 不能为空，后端仅支持 PostgreSQL")
	}

	db, err = gorm.Open(postgres.Open(cfg.DSN), &gorm.Config{})
	if err != nil {
		log.Fatal("数据库连接失败:", err)
	}
	log.Println("使用 PostgreSQL 数据库")

	// 注册全局 GORM 错误日志钩子 (安全网)
	logDBError := func(db *gorm.DB) {
		if db.Error != nil && !errors.Is(db.Error, gorm.ErrRecordNotFound) {
			log.Printf("[DB_ERROR] table=%s statement=%s err=%v", db.Statement.Table, db.Statement.SQL.String(), db.Error)
		}
	}
	db.Callback().Query().After("gorm:query").Register("audit:log_errors_query", logDBError)
	db.Callback().Create().After("gorm:create").Register("audit:log_errors_create", logDBError)
	db.Callback().Update().After("gorm:update").Register("audit:log_errors_update", logDBError)
	db.Callback().Delete().After("gorm:delete").Register("audit:log_errors_delete", logDBError)
	db.Callback().Row().After("gorm:row").Register("audit:log_errors_row", logDBError)
	db.Callback().Raw().After("gorm:raw").Register("audit:log_errors_raw", logDBError)

	// 自动迁移

	if err := models.NormalizeConversationPairs(db); err != nil {
		log.Fatalf("failed to normalize legacy conversations: %v", err)
	}
	if err := models.PrepareCompetitionCatalogMigration(db); err != nil {
		log.Fatal("竞赛目录预迁移失败:", err)
	}

	if err := db.AutoMigrate(

		&models.User{},
		&models.EmailVerificationChallenge{},
		&models.EmailVerificationRequest{},
		&models.AccountSecurityAuditLog{},

		&models.UserLegalConsent{},

		&models.PersonalDataRequest{},
		&models.EduCredentialCleanupJob{},
		&models.AcademicSnapshot{},
		&models.PersonalUploadedSnapshot{},
		&models.AIUserPermission{},
		&models.AIRunConsent{},
		&models.UserDevice{},
		&models.DeviceToolJob{},

		&models.Post{},
		&models.Poll{},
		&models.PollOption{},
		&models.PollBallot{},
		&models.PollBallotChoice{},

		&models.WaterSection{},

		&models.WaterSectionIconReview{},

		&models.WaterSectionTag{},

		&models.WaterSectionModerator{},

		&models.WaterSectionPin{},

		&models.WaterSectionFeaturedPost{},

		// 水帖版块等级 / 经验 / 称号
		&models.WaterSectionUserStat{},
		&models.WaterSectionExpLog{},
		&models.WaterSectionLevelTitle{},
		&models.WaterSectionFollow{},

		&models.WaterSectionMute{},

		&models.WaterModerationLog{},

		&models.PostImage{},
		&models.WaterTeamRecruitment{},
		&models.WaterTeamApplication{},
		&models.FeaturedApplication{},
		&models.CollaborationApplication{},
		&models.PostRevisionProposal{},
		&models.ReputationLog{},

		&models.Reply{},

		&models.ReplyImage{},

		&models.Like{},

		&models.File{},
		&models.FileUploadGrant{},
		&models.UserEmojiAsset{},
		&models.UserEmojiFavorite{},

		&models.ExamPaper{},

		&models.ExamPaperUploadSession{},

		&models.ExamPaperStorageJob{},

		&models.Conversation{},

		&models.Message{},

		&models.Announcement{},

		&models.Report{},

		&models.Appeal{},

		&models.AppealVote{},

		&models.Invitation{},

		&models.InvitationVote{},

		&models.AdminActionLog{},

		&models.Tutorial{},

		&models.Teacher{},

		&models.TeacherRating{},
		&models.TeacherRatingVote{},

		&models.UserViolation{},

		&models.AdminLog{},

		&models.AnnouncementRead{},

		&models.Major{},

		&models.MajorRating{},
		&models.MajorRatingVote{},

		&models.AdminVote{},

		&models.AdminRemovalVote{},

		&models.Notification{},

		&models.ExpLog{},

		&models.LotteryEvent{},

		&models.LotteryParticipant{},

		&models.SystemConfig{},
		&models.Canteen{},
		&models.CanteenRating{},
		&models.CanteenRatingVote{},
		&models.CanteenDish{},
		&models.CanteenDishPhoto{},
		&models.CanteenRatingDishRecommendation{},
		&models.CanteenReviewEvent{},
		&models.CanteenReviewEventDish{},
		&models.CanteenDishReviewEvent{},
		&models.CanteenDishRatingSummary{},
		&models.CanteenDishAlias{},
		&models.CanteenSanction{},
		&models.UserFollow{},

		// Feed 推荐系统（FEED-1 / FEED-2 / FEED-4）
		&models.FeedFeedback{},
		&models.UserHiddenAuthor{},
		&models.FeedImpression{},
		&models.FeedDailyMetrics{},
		&models.FeedRankTrace{},

		// 校园资讯
		&models.CampusArticle{},
		&models.JWCSyncState{},
		&models.CompetitionCategory{},
		&models.CompetitionCatalogPackage{},
		&models.CompetitionCatalogAuditLog{},
		&models.CompetitionCatalogLegacyMapping{},
		&models.CompetitionLegacyDuplicateResolution{},
		&models.CompetitionCatalogActivationSnapshot{},
		&models.CompetitionEvent{},
		&models.CompetitionEventAttachment{},
		&models.UserCompetitionCalendar{},
		&models.UserCompetitionCalendarItem{},
		&models.CalendarShareSnapshot{},
		&models.CalendarShareSnapshotItem{},
		&models.CompetitionImportBatch{},
		&models.UserCompetitionPreference{},
		&models.CompetitionRecommendationSnapshot{},
		&models.AIActionDraft{},
		&models.AIActionAuditLog{},
		&models.UserCompetitionAward{},
		&models.CompetitionAwardVerificationLog{},
		&models.CompetitionAwardEvidenceFile{},
		&models.CompetitionAwardEvidence{},
		&models.CompetitionAwardEvidenceAccessLog{},
		&models.CampusCalendar{},
		&models.AIKnowledgeDocument{},
		&models.AIKnowledgeAuditLog{},

		// 应用内更新：APK 发布记录
		&models.AppRelease{},
	); err != nil {

		log.Fatal("数据库迁移失败:", err)

	}
	if err := ensureSecurityHardeningSchema(db); err != nil {
		log.Fatal("安全加固数据库迁移失败:", err)
	}
	if err := models.BackfillCompetitionCatalogMetadata(db); err != nil {
		log.Fatal("竞赛目录兼容数据回填失败:", err)
	}
	accountRepair, err := models.RepairLegacyAccountIdentityState(db)
	if err != nil {
		log.Fatal("历史账号身份状态修复失败:", err)
	}
	if accountRepair.VerifiedStudents > 0 || accountRepair.RestoredAuthorizations > 0 {
		log.Printf("历史账号身份状态已修复: verified_students=%d restored_authorizations=%d",
			accountRepair.VerifiedStudents, accountRepair.RestoredAuthorizations)
	}
	// 新推送授权默认关闭，旧 Token 不得被视为用户已主动同意。
	if err := db.Model(&models.User{}).
		Where("push_data_processing_enabled = ?", false).
		Updates(map[string]interface{}{
			"device_token":         "",
			"push_installation_id": "",
			"push_notice_version":  "",
			"push_enabled_at":      nil,
		}).Error; err != nil {
		log.Fatal("历史推送 Token 清理失败:", err)
	}
	// 旧客户端的一次性六项确认只保留为历史捆绑证据，不能升级成独立功能授权。
	if err := db.Model(&models.UserLegalConsent{}).
		Where("document IN ? AND acknowledgement_type <> ?", []string{
			models.LegalDocumentCommunityRules,
			models.LegalDocumentMinorProtection,
			models.LegalDocumentContentComplaint,
			models.LegalDocumentSDKDisclosure,
		}, "rules_acceptance").
		Updates(map[string]interface{}{
			"acknowledgement_type": "legacy_bundled",
			"scope":                "legacy",
			"scene":                "migration",
		}).Error; err != nil {
		log.Fatal("历史捆绑授权标记失败:", err)
	}
	if err := models.BackfillLegacyMarketContacts(db); err != nil {
		log.Fatal("历史集市联系方式回填失败:", err)
	}

	if err := models.EnsureExamPaperIndexes(db); err != nil {
		log.Fatal("试卷索引迁移失败:", err)
	}
	if err := models.EnsureCheckInSchema(db); err != nil {
		log.Fatal("签到系统迁移失败:", err)
	}
	if err := models.EnsureCampusCalendarIndexes(db); err != nil {
		log.Fatal("校历索引迁移失败:", err)
	}
	if err := ensureCanteenNormalizedNameIndex(db); err != nil {
		log.Fatal("食堂名称唯一索引迁移失败:", err)
	}
	if err := models.EnsureCanteenOperatingStatusSchema(db); err != nil {
		log.Fatal("食堂营业状态迁移失败:", err)
	}
	if err := models.EnsureCanteenDishSchema(db); err != nil {
		log.Fatal("食堂菜品图库约束迁移失败:", err)
	}
	if err := models.EnsureCanteenRatingRecommendationSchema(db); err != nil {
		log.Fatal("食堂评价菜品推荐约束迁移失败:", err)
	}
	if err := models.EnsureCanteenReviewSchema(db); err != nil {
		log.Fatal("食堂评价 V2 结构迁移失败:", err)
	}
	if err := ensureAppReleaseIndexes(db); err != nil {
		log.Fatal("应用发布索引迁移失败:", err)
	}

	if err := models.EnsureConversationIndexes(db); err != nil {
		log.Fatal("私信索引迁移失败:", err)
	}
	if err := models.ApplyCompetitionRatingMigration(db); err != nil {
		log.Fatal("竞赛评级字段迁移失败:", err)
	}
	if err := models.VerifyCompetitionCalendarDedupMigration(db); err != nil {
		log.Fatal("竞赛计划数据约束未就绪:", err)
	}
	if err := models.EnsureCompetitionCategories(db); err != nil {
		log.Fatal("竞赛分类种子初始化失败:", err)
	}
	if err := models.EnsureWaterSections(db); err != nil {
		log.Fatal("初始化默认版块失败:", err)
	}
	if err := models.MigrateLegacyTeamRecruitmentTag(db); err != nil {
		log.Fatal("迁移历史组队标签失败:", err)
	}
	if err := models.ValidateNoDuplicateTeamTags(db); err != nil {
		log.Fatal("校验重复组队标签失败:", err)
	}
	if err := models.EnsureWaterTeamSchema(db); err != nil {
		log.Fatal("确保组队模块数据库约束失败:", err)
	}
	if err := ensureFeatureCollaborationIndexes(db); err != nil {
		log.Fatal("精华共同创作索引迁移失败:", err)
	}
	if err := ensurePostMarketTagsColumn(db); err != nil {
		log.Fatal("商品交易选项字段迁移失败:", err)
	}
	if err := ensurePostPinColumns(db); err != nil {
		log.Fatal("帖子置顶字段迁移失败:", err)
	}
	if err := ensurePostActivitySchema(db); err != nil {
		log.Fatal("帖子活跃时间迁移失败:", err)
	}
	if err := models.EnsurePollSchema(db); err != nil {
		log.Fatal("投票系统数据库约束未就绪:", err)
	}
	if err := models.EnsureRatingInteractionSchema(db); err != nil {
		log.Fatal("评价交互系统数据库约束未就绪:", err)
	}

	// 回填旧公告的缺失字段默认值（公告模型新增 Status/DisplayMode/Priority）
	db.Exec(`UPDATE announcements SET status = 'published' WHERE status = ''`)
	db.Exec(`UPDATE announcements SET display_mode = 'center' WHERE display_mode = ''`)
	db.Exec(`UPDATE announcements SET priority = 'normal' WHERE priority = ''`)

	// 全表统计回算不应阻塞服务启动；需要修复历史数据时使用独立运维任务执行。
	log.Println("跳过启动期全表统计回算")

	// 确保默认超级管理员

	ensureSystemSuperAdmin(db, cfg.SuperAdminID, cfg.SuperAdminPass)

	r := gin.Default()

	// CORS 仅允许显式配置的可信来源，生产环境不能反射任意 Origin。
	allowedOrigins := make(map[string]struct{})
	for _, origin := range strings.Split(os.Getenv("CORS_ALLOW_ORIGINS"), ",") {
		if origin = strings.TrimSpace(origin); origin != "" {
			allowedOrigins[origin] = struct{}{}
		}
	}
	if len(allowedOrigins) == 0 && os.Getenv("GIN_MODE") != "release" {
		allowedOrigins["http://localhost:3000"] = struct{}{}
		allowedOrigins["http://localhost:8080"] = struct{}{}
	}
	r.Use(func(c *gin.Context) {
		origin := c.GetHeader("Origin")
		if origin != "" {
			if _, allowed := allowedOrigins[origin]; !allowed {
				if c.Request.Method == "OPTIONS" {
					c.AbortWithStatus(http.StatusForbidden)
					return
				}
				c.Next()
				return
			}
			c.Header("Access-Control-Allow-Origin", origin)
			c.Header("Access-Control-Allow-Credentials", "true")
		}

		c.Header("Access-Control-Allow-Methods", "GET, POST, PUT, PATCH, DELETE, OPTIONS")

		c.Header("Access-Control-Allow-Headers", "Content-Type, Authorization, X-App-Platform, X-App-Channel, X-App-Version-Name, X-App-Version-Code")

		if c.Request.Method == "OPTIONS" {

			c.AbortWithStatus(204)

			return

		}

		c.Next()

	})

	// 法律页面无需登录和客户端版本头，供浏览器、下载页和分享页访问。
	r.StaticFile("/terms", filepath.Join("static", "legal", "terms.html"))
	r.StaticFile("/privacy", filepath.Join("static", "legal", "privacy.html"))
	// 公共表情使用内容寻址 ID，可长期缓存且不依赖登录态或版本请求头。
	r.GET("/stickers/:id", handlers.ServeSticker)
	r.HEAD("/stickers/:id", handlers.ServeSticker)

	// 最低支持版本拦截位于 CORS 之后、业务路由之前。公开更新接口和迁移期
	// 登录接口由中间件内部放行，避免用户在被拦截后无法获得新安装包。
	r.Use(middleware.AppVersionMiddleware(
		db,
		cfg.AppUpdateEnforcementEnabled,
		cfg.AllowMissingVersionHeaders,
	))

	// 初始化跨服务和邮件配置。生产身份数据迁移仍由显式 SQL 完成。
	handlers.EduServiceConfig.BaseURL = cfg.EduServiceURL
	handlers.EduServiceConfig.Token = cfg.EduServiceToken
	handlers.VerifyCodeConfig.SMTPHost = cfg.SMTPHost
	handlers.VerifyCodeConfig.SMTPPort = cfg.SMTPPort
	handlers.VerifyCodeConfig.SMTPUser = cfg.SMTPUser
	handlers.VerifyCodeConfig.SMTPPass = cfg.SMTPPass
	handlers.VerifyCodeConfig.SMTPFrom = cfg.SMTPFrom
	emailVerification := services.NewEmailVerificationService(
		db,
		services.NewSMTPVerificationMailer(services.SMTPConfig{
			Host: cfg.SMTPHost, Port: cfg.SMTPPort, User: cfg.SMTPUser, Pass: cfg.SMTPPass, From: cfg.SMTPFrom,
		}),
		cfg.JWTSecret,
		time.Now,
	)

	// 初始化处理器

	eduCredentialCleanupJobs := services.NewEduCredentialCleanupJobService(db, handlers.PythonEduCredentialCleanupRemote{}, time.Now)
	eduBindingRecovery := services.NewEduBindingRecoveryService(db, handlers.PythonEduBindingRecoveryRemote{}, eduCredentialCleanupJobs, time.Now)
	academicSnapshotService := services.NewAcademicSnapshotService(db, time.Now)
	personalSnapshotService := services.NewPersonalSnapshotService(db, time.Now)
	eduClient := clients.NewEduClient(clients.EduClientOptions{
		BaseURL: func() string { return cfg.EduServiceURL },
		Token:   func() string { return cfg.EduServiceToken },
	})
	eduFetchOrchestrator := services.NewEduFetchOrchestrator(
		db,
		eduClient,
		academicSnapshotService,
		services.EduFetchOrchestratorOptions{},
	)
	authHandler := handlers.NewAuthHandlerWithEmailVerificationAndCleanup(db, cfg.JWTSecret, emailVerification, eduCredentialCleanupJobs)

	userHandler := handlers.NewUserHandler(db)
	privacyHandler := handlers.NewPrivacyHandlerWithEduCredentialCleanup(db, eduCredentialCleanupJobs)

	postHandler := handlers.NewPostHandler(db, cfg.JPushAppKey, cfg.JPushMasterSecret)
	postHandler.SetFeedPersonalization(cfg.HomeFeedPersonalizationShadow, cfg.HomeFeedPersonalizationPercent)
	postHandler.SetFeedPersonalizationV5(cfg.HomeFeedV5PersonalizationShadow, cfg.HomeFeedV5PersonalizationPercent)
	feedHandler := handlers.NewFeedHandler(db)
	feedEventHandler := handlers.NewFeedEventHandler(db)
	feedMetricsHandler := handlers.NewFeedMetricsHandler(db)
	pollHandler := handlers.NewPollHandler(db)
	searchHandler := handlers.NewSearchHandler(db, postHandler)
	competitionHandler, competitionHandlerErr := handlers.NewCompetitionHandlerWithEvidenceStorage(
		db, cfg.CompetitionAwardEvidenceDir, cfg.MaxFileSize,
	)
	if competitionHandlerErr != nil {
		log.Fatal("初始化竞赛证明材料私有存储失败:", competitionHandlerErr)
	}

	waterSectionHandler := handlers.NewWaterSectionHandler(db)
	waterModeratorHandler := handlers.NewWaterModeratorHandler(db)
	waterModerationHandler := handlers.NewWaterModerationHandler(db)
	waterTeamHandler := handlers.NewWaterTeamHandler(db)
	waterTeamHandler.NotifyDeadlineSoon()
	go func() {
		ticker := time.NewTicker(6 * time.Hour)
		defer ticker.Stop()
		for range ticker.C {
			waterTeamHandler.NotifyDeadlineSoon()
		}
	}()

	replyHandler := handlers.NewReplyHandler(db, cfg.JPushAppKey, cfg.JPushMasterSecret)

	likeHandler := handlers.NewLikeHandler(db)

	messageHandler := handlers.NewMessageHandler(db, services.NewNotificationService(cfg.JPushAppKey, cfg.JPushMasterSecret))
	messageHandler.SetUploadDir(cfg.UploadDir)

	announcementHandler := handlers.NewAnnouncementHandler(db)

	reportHandler := handlers.NewReportHandler(db)

	appealHandler := handlers.NewAppealHandler(db)

	invitationHandler := handlers.NewInvitationHandler(db, cfg.JWTSecret)

	uploadHandler := handlers.NewUploadHandler(cfg.UploadDir, cfg.MaxFileSize, db)

	emojiFavoriteService := services.NewEmojiFavoriteService(db, cfg.UploadDir)
	emojiFavoriteHandler := handlers.NewEmojiFavoriteHandler(emojiFavoriteService)

	examPaperFiles, examPaperFileErr := services.NewExamPaperFileService(cfg.ExamPaperDir)
	if examPaperFileErr != nil {
		log.Fatal("初始化试卷私有文件目录失败:", examPaperFileErr)
	}
	if examPaperFileErr = examPaperFiles.RecoverTrash(db); examPaperFileErr != nil {
		log.Fatal("恢复试卷私有文件失败:", examPaperFileErr)
	}
	var examPaperUploads *services.ExamPaperUploadService
	var examPaperRemote *services.ExamPaperRemoteClient
	var examPaperStorageJobs *services.ExamPaperStorageJobService
	var examPaperStorageMaintenance *services.ExamPaperStorageMaintenance
	if cfg.ExamPaperStorageMode != config.ExamPaperStorageModeLocal {
		grantSigner, signerErr := services.NewExamPaperStorageSigner(cfg.ExamPaperStorageSigningSecret, time.Now)
		if signerErr != nil {
			log.Fatal("初始化试卷存储授权签名器失败:", signerErr)
		}
		receiptSigner, receiptErr := services.NewExamPaperStorageSigner(cfg.ExamPaperStorageReceiptSecret, time.Now)
		if receiptErr != nil {
			log.Fatal("初始化试卷上传回执签名器失败:", receiptErr)
		}
		examPaperRemote, signerErr = services.NewExamPaperRemoteClient(cfg.ExamPaperStorageBaseURL, grantSigner, nil, time.Now)
		if signerErr != nil {
			log.Fatal("初始化试卷远端存储客户端失败:", signerErr)
		}
		examPaperStorageJobs = services.NewExamPaperStorageJobService(db, examPaperRemote, time.Now)
		examPaperStorageMaintenance = services.NewExamPaperStorageMaintenance(db, examPaperRemote, nil)
		examPaperUploads = services.NewExamPaperUploadService(db, grantSigner, receiptSigner, time.Now, newExamPaperStorageJobAttempt(examPaperStorageJobs))
	}
	examPaperHandler := handlers.NewExamPaperHandlerWithStorage(
		db,
		examPaperFiles,
		cfg.ExamPaperStorageMode,
		cfg.ExamPaperStorageBaseURL,
		examPaperUploads,
		examPaperRemote,
		examPaperStorageJobs,
	)

	superAdminHandler := handlers.NewSuperAdminHandler(db)

	// 应用内更新：阶段 A 暴露公开版本检查接口。APK 下载路由在阶段 A5 追加。
	appReleaseService := services.NewAppReleaseService(db, cfg.AppReleaseDir, cfg.AppReleaseMaxSize)
	appUpdateHandler := handlers.NewAppUpdateHandler(
		appReleaseService,
		cfg.AppReleaseUseAccelRedirect,
		cfg.AppReleaseAccelPrefix,
	)

	eduHandler := handlers.NewEduHandlerWithAcademicFetch(db, cfg.JWTSecret, eduCredentialCleanupJobs, eduFetchOrchestrator)
	deviceJobService := services.NewDeviceJobService(db)
	deviceJobHandler := handlers.NewDeviceJobHandler(deviceJobService)
	aiUserPermissionService := services.NewAIUserPermissionService(db)
	aiUserPermissionHandler := handlers.NewAIUserPermissionHandler(aiUserPermissionService)
	personalSnapshotHandler := handlers.NewPersonalSnapshotHandler(personalSnapshotService)
	personalSnapshotHandler.SetAIUserPermissionService(aiUserPermissionService)

	teacherHandler := handlers.NewTeacherHandler(db)

	majorHandler := handlers.NewMajorHandler(db)

	canteenHandler := handlers.NewCanteenHandler(db)
	canteenDishHandler := handlers.NewCanteenDishHandler(db)
	canteenDishPhotoHandler := handlers.NewCanteenDishPhotoHandler(db)
	canteenDishPhotoAdminHandler := handlers.NewCanteenDishPhotoAdminHandler(db)

	feedbackHandler := handlers.NewFeedbackHandler(db, cfg.UploadDir)

	checkinHandler := handlers.NewCheckInHandler(db)
	checkinCompensationHandler := handlers.NewCheckInCompensationHandler(db)

	notificationHandler := handlers.NewNotificationHandler(db)

	erkeHandler := handlers.NewErkeHandler(db)

	lotteryHandler := handlers.NewLotteryHandler(db)

	handlers.SetMajorLogDB(db)

	// JWC 校园资讯同步
	var campusSyncServices []*services.CampusSyncService
	if cfg.JWCSyncEnabled {
		jwcClient := clients.NewJWCPythonClient(cfg.EduServiceURL, cfg.EduServiceToken)

		// JWC sync (教务通知 + 教务公告)
		jwcSpec := services.CrawlSourceSpec{
			Source:     "jwc",
			Categories: []string{"jwtz", "jwgg"},
			CrawlFunc: func(ctx context.Context, knownURLs map[string][]string, maxPages int, reconcile bool) (*clients.CrawlResponse, error) {
				return jwcClient.Crawl(ctx, &clients.CrawlRequest{
					Categories:      []string{"jwtz", "jwgg"},
					KnownSourceURLs: knownURLs,
					MaxPages:        maxPages,
					Reconcile:       reconcile,
				})
			},
		}
		campusSyncServices = append(campusSyncServices, services.NewCampusSyncService(db, jwcSpec))

		// Competition sync (创新创业学院比赛通知)
		competitionSpec := services.CrawlSourceSpec{
			Source:     "cxcy",
			Categories: []string{"competition"},
			CrawlFunc: func(ctx context.Context, knownURLs map[string][]string, maxPages int, reconcile bool) (*clients.CrawlResponse, error) {
				// 合并所有已知 URL 为扁平列表（Python competition 端接收 list）
				var allURLs []string
				for _, urls := range knownURLs {
					allURLs = append(allURLs, urls...)
				}
				return jwcClient.CrawlCompetition(ctx, &clients.CompetitionCrawlRequest{
					KnownSourceURLs: allURLs,
					MaxPages:        maxPages,
					Reconcile:       reconcile,
				})
			},
		}
		campusSyncServices = append(campusSyncServices, services.NewCampusSyncService(db, competitionSpec))

		go tasks.StartCampusSyncTask(appCtx, campusSyncServices, cfg)
		log.Println("校园资讯同步已启用 (JWC + Competition)")
	} else {
		log.Println("校园资讯同步未启用 (JWC_SYNC_ENABLED=false)")
	}

	campusArticleHandler := handlers.NewCampusArticleHandler(db, campusSyncServices...)
	campusCalendarHandler := handlers.NewCampusCalendarHandler(db)
	classPeriodProfileHandler := handlers.NewClassPeriodProfileHandler(db)

	var ragClient *ai.RAGClient
	var aiRuntime *ai.Runtime
	var externalMCPClient *mcpclient.Client
	var toolRegistry *ai.ToolRegistry
	if cfg.AIEnabled && cfg.AIPolicyRAGEnabled {
		if schemaErr := models.ValidateAIRuntimeSchema(db); schemaErr != nil {
			log.Fatalf("AI Runtime Schema 未就绪，请依次执行 AI SQL 迁移（含 20260727_ai_langchain_ingestion.sql 与 20260727_ai_langchain_retrieval.sql）: %v", schemaErr)
		}
		ragHTTPClient := &http.Client{Timeout: time.Duration(cfg.AIRequestTimeoutSeconds) * time.Second}
		var ragErr error
		ragClient, ragErr = ai.NewRAGClient(cfg.RAGServiceURL, cfg.RAGServiceToken, ragHTTPClient)
		if ragErr != nil {
			log.Fatalf("AI RAG 配置无效: %v", ragErr)
		}
		var provider ai.AIProvider
		var retriever ai.PolicyRetriever
		runtimeOptions := make([]ai.RuntimeOption, 0, 1)
		providerName, modelName := cfg.AIProvider, cfg.AIChatModel
		if cfg.AILangChainRAGEnabled {
			providerName, modelName = "rag-rollout", "policy-rag"
			runtimeOptions = append(runtimeOptions, ai.WithLangChainRAG(ragClient))
		}
		if cfg.AILegacyRAGEnabled {
			// 灰度期只为分配到旧路径的请求调用这些依赖，同一请求不会双重检索或生成。
			retriever = ai.NewHybridRetriever(db, ragClient, cfg.RAGEmbeddingModelVersion)
			if cfg.AIProvider == "mock" {
				provider = &ai.MockProvider{Response: ai.ChatResponse{Content: "当前是 Mock Provider 回答。", InputTokens: 1, OutputTokens: 1}}
			} else {
				providerHTTPClient := &http.Client{Timeout: time.Duration(cfg.AIRequestTimeoutSeconds) * time.Second}
				provider, ragErr = ai.NewOpenAICompatibleProvider(cfg.AIBaseURL, cfg.AIAPIKey, cfg.AIChatModel, providerHTTPClient)
				if ragErr != nil {
					log.Fatalf("AI Provider 初始化失败: %v", ragErr)
				}
			}
		}
		deviceJobScheduler := ai.DeviceJobSchedulerFunc(func(ctx context.Context, request ai.DeviceJobRequest) (ai.DeviceJobReference, error) {
			job, err := deviceJobService.CreateJob(ctx, services.CreateDeviceJobRequest{
				UserID: request.UserID, RunID: request.RunID, ToolCallID: request.ToolCallID,
				ToolName: request.ToolName, Arguments: request.Arguments, RequiredDataTypes: request.RequiredDataTypes,
				ExpiresAt: request.ExpiresAt,
			})
			if err != nil {
				return ai.DeviceJobReference{}, err
			}
			return ai.DeviceJobReference{ID: job.ID}, nil
		})
		policyRetriever := ai.NewHybridRetriever(db, ragClient, cfg.RAGEmbeddingModelVersion)
		tools := ai.NewCampusMCPTools(
			db, academicSnapshotService, personalSnapshotService,
			ai.WithCampusPolicyRetriever(policyRetriever),
			ai.WithCampusDeviceJobScheduler(deviceJobScheduler),
			ai.WithCampusPersonalDataPermissionReader(aiUserPermissionService),
		)
		if cfg.AIExternalMCPEnabled {
			var externalMCPErr error
			externalMCPClient, externalMCPErr = mcpclient.New(mcpclient.Config{
				Enabled:           true,
				Transport:         cfg.AIExternalMCPTransport,
				Command:           cfg.AIExternalMCPCommand,
				ToolTimeout:       time.Duration(cfg.AIExternalMCPToolTimeoutSeconds) * time.Second,
				MaxCallsPerRun:    cfg.AIExternalMCPMaxCallsPerRun,
				SSHHost:           cfg.AIExternalMCPSshHost,
				SSHPort:           cfg.AIExternalMCPSshPort,
				SSHUser:           cfg.AIExternalMCPSshUser,
				SSHKeyPath:        cfg.AIExternalMCPSshKeyPath,
				SSHKnownHostsPath: cfg.AIExternalMCPKnownHostsPath,
			}, nil)
			if externalMCPErr != nil {
				log.Printf("[AI_EXTERNAL_MCP_CONFIGURATION_INVALID] %v", externalMCPErr)
			} else {
				defer func() {
					if err := externalMCPClient.Close(); err != nil {
						log.Printf("[AI_EXTERNAL_MCP_CLOSE_FAILED] %v", err)
					}
				}()
				connectCtx, cancelConnect := context.WithTimeout(appCtx, time.Duration(cfg.AIExternalMCPToolTimeoutSeconds)*time.Second)
				externalMCPErr = externalMCPClient.Connect(connectCtx)
				cancelConnect()
				if externalMCPErr != nil {
					log.Printf("[AI_EXTERNAL_MCP_CONNECT_FAILED] code=%s", mcpclient.ErrorCode(externalMCPErr))
				} else {
					log.Printf("独立 Hy3 MCP 已完成 stdio 健康检查 transport=%s", cfg.AIExternalMCPTransport)
					listCtx, cancelList := context.WithTimeout(appCtx, time.Duration(cfg.AIExternalMCPToolTimeoutSeconds)*time.Second)
					definitions, listErr := externalMCPClient.ListTools(listCtx)
					cancelList()
					if listErr != nil {
						log.Printf("[AI_EXTERNAL_MCP_TOOL_LIST_FAILED] code=%s", mcpclient.ErrorCode(listErr))
					} else {
						hy3Tools := ai.NewValidatedHy3DecisionTools(
							db, academicSnapshotService, personalSnapshotService, externalMCPClient, definitions,
							ai.WithHy3DecisionPersonalDataPermissionReader(aiUserPermissionService),
							ai.WithHy3CompetitionExplanationEnabled(cfg.CompetitionAIExplanationEnabled),
							ai.WithHy3CompetitionCandidateBuilder(func(
								ctx context.Context,
								userID uint,
								eventIDs []uint,
							) ([]dto.CompetitionCandidateDTO, error) {
								result, err := services.NewCompetitionCandidateEngine(db).BuildCandidates(
									ctx,
									userID,
									services.CandidateFilter{
										Page: 1, PageSize: len(eventIDs), EventIDs: eventIDs,
									},
								)
								if err != nil {
									return nil, err
								}
								items := make([]dto.CompetitionCandidateDTO, 0, result.Total)
								for _, group := range result.Groups {
									items = append(items, group.Items...)
								}
								return items, nil
							}),
						)
						if len(hy3Tools) == 0 {
							log.Printf("[AI_EXTERNAL_MCP_NO_COMPATIBLE_TOOLS]")
						} else {
							tools = append(tools, hy3Tools...)
							for _, tool := range hy3Tools {
								if tool.Name() == "hy3_decision.explain_competition_candidates" {
									competitionHandler.SetCompetitionCandidateExplanationTool(tool)
								}
							}
						}
					}
				}
			}
		}
		var registryErr error
		toolRegistry, registryErr = ai.NewToolRegistry(db, tools...)
		if registryErr != nil {
			log.Fatalf("校园 MCP 工具注册失败: %v", registryErr)
		}
		runtimeOptions = append(runtimeOptions, ai.WithToolRegistry(toolRegistry))
		aiRuntime, ragErr = ai.NewRuntime(
			db, provider, retriever, ai.NewEventBroker(),
			ai.RuntimeConfig{
				ProviderName: providerName, Model: modelName,
				RequestTimeout:  time.Duration(cfg.AIRequestTimeoutSeconds) * time.Second,
				MaxOutputTokens: cfg.AILegacyMaxOutputTokens,
				MaxToolSteps:    cfg.AIMaxToolSteps,
				MaxMessageChars: cfg.AIMaxMessageChars, HourlyMessageLimit: cfg.AIHourlyMessageLimit,
				UnlimitedStudentIDs:            cfg.AIUnlimitedStudentIDs,
				QuotaExemptUserIDs:             cfg.AIQuotaExemptUserIDs,
				DefaultBudgetLimitMicroYuan:    cfg.AIUserBudgetLimitMicroYuan,
				ReservationMicroYuan:           cfg.AIReserveMicroYuan,
				InputPriceMicroYuanPerMillion:  cfg.AIInputPriceMicroYuanPerMillionTokens,
				OutputPriceMicroYuanPerMillion: cfg.AIOutputPriceMicroYuanPerMillionTokens,
				AuditHashSecret:                cfg.JWTSecret,
				LangChainRAGEnabled:            cfg.AILangChainRAGEnabled,
				LangChainRAGRolloutPercent:     cfg.AILangChainRAGRolloutPercent,
				LegacyRAGEnabled:               cfg.AILegacyRAGEnabled,
			},
			runtimeOptions...,
		)
		if ragErr != nil {
			log.Fatalf("AI Runtime 初始化失败: %v", ragErr)
		}
		deviceJobHandler.SetRunResumer(aiRuntime)
		eduHandler.SetUserConsentRunResumer(aiRuntime)
		if ragErr := aiRuntime.RecoverAbandonedRuns(appCtx); ragErr != nil {
			log.Printf("[AI_RECOVERY_FAILED] %v", ragErr)
		}
		ingestionWorker := services.NewKnowledgeIngestionWorker(db, ragClient, cfg.RAGEmbeddingModelVersion)
		go ingestionWorker.Start(appCtx)
		go func() {
			ticker := time.NewTicker(time.Minute)
			defer ticker.Stop()
			for {
				select {
				case <-appCtx.Done():
					return
				case <-ticker.C:
					if err := aiRuntime.ReclaimExpiredReservations(appCtx); err != nil {
						log.Printf("[AI_BUDGET_RECLAIM_FAILED] %v", err)
					}
				}
			}
		}()
	}
	knowledgeHandler := handlers.NewAIKnowledgeHandler(db, ragClient)
	aiCapabilitiesHandler := handlers.NewAICapabilitiesHandler(
		cfg.AIEnabled,
		handlers.AICapabilitiesOptions{
			Runtime: aiRuntime, PolicyRAGEnabled: cfg.AIPolicyRAGEnabled && aiRuntime != nil,
			HourlyLimit:           cfg.AIHourlyMessageLimit,
			MaxMessageChars:       cfg.AIMaxMessageChars,
			QuotaExemptUserIDs:    cfg.AIQuotaExemptUserIDs,
			ExternalMCPConfigured: cfg.AIExternalMCPEnabled,
			ExternalMCPHealth:     externalMCPClient,
			ToolRegistry:          toolRegistry,
		},
	)
	var aiRuntimeHandler *handlers.AIRuntimeHandler
	if aiRuntime != nil {
		aiRuntimeHandler = handlers.NewAIRuntimeHandler(db, aiRuntime)
	}

	// 启动后台定时任务

	tasks.StartLotteryCron(db)
	feedMetricsCron := tasks.StartFeedMetricsCron(appCtx, services.NewFeedMetricsService(db))
	var examPaperStorageCron *tasks.ExamPaperStorageCron
	if examPaperStorageJobs != nil && examPaperStorageMaintenance != nil {
		examPaperStorageCron = tasks.StartExamPaperStorageCron(appCtx, examPaperStorageJobs, examPaperStorageMaintenance)
	}
	eduCredentialCleanupCron := tasks.StartEduCredentialCleanupCron(appCtx, eduCredentialCleanupJobs)
	eduBindingRecoveryCron := tasks.StartEduBindingRecoveryCron(appCtx, eduBindingRecovery)

	// 应用内更新：公开版本检查接口，不需要登录。下载路由在阶段 A5 追加。
	appPublic := r.Group("/api/app")
	{
		appPublic.GET("/update", appUpdateHandler.CheckUpdate)
		appPublic.GET("/releases/:id/download", appUpdateHandler.Download)
		appPublic.HEAD("/releases/:id/download", appUpdateHandler.Download)
	}

	// 健康检查接口
	r.GET("/health", func(c *gin.Context) {
		sqlDB, err := db.DB()
		if err != nil {
			c.JSON(http.StatusServiceUnavailable, gin.H{
				"status": "error",
			})
			return
		}

		ctx, cancel := context.WithTimeout(
			c.Request.Context(),
			2*time.Second,
		)
		defer cancel()

		if err := sqlDB.PingContext(ctx); err != nil {
			c.JSON(http.StatusServiceUnavailable, gin.H{
				"status": "error",
			})
			return
		}

		ragHealth := "disabled"
		if cfg.AIPolicyRAGEnabled {
			ragHealth = "unavailable"
			if ragClient != nil {
				ragCtx, ragCancel := context.WithTimeout(c.Request.Context(), 800*time.Millisecond)
				if err := ragClient.Health(ragCtx); err == nil {
					ragHealth = "ok"
				}
				ragCancel()
			}
		}
		c.JSON(http.StatusOK, gin.H{
			"status": "ok",
			"ai": gin.H{
				"enabled":         cfg.AIEnabled,
				"runtime_enabled": aiRuntime != nil,
				"external_mcp":    externalMCPHealthPayload(cfg.AIExternalMCPEnabled, externalMCPClient, toolRegistry),
				"policy_rag": gin.H{
					"enabled": cfg.AIPolicyRAGEnabled, "langchain_enabled": cfg.AILangChainRAGEnabled,
					"langchain_rollout_percent": cfg.AILangChainRAGRolloutPercent,
					"legacy_go_enabled":         cfg.AILegacyRAGEnabled,
					"status":                    ragHealth,
				},
			},
		})
	})

	// 设备工具桥接使用普通 JWT 鉴权，不能依赖校园 Agent 内测开关；
	// 已登记安装实例仍须在每个 Handler 中按 user_id + installation_id 双重校验。
	deviceAPI := r.Group("/api/device")
	deviceAPI.Use(middleware.AuthMiddleware(db, cfg.JWTSecret))
	{
		deviceAPI.PUT("/registration", deviceJobHandler.Register)
		deviceAPI.GET("/jobs/pending", deviceJobHandler.Pending)
		deviceAPI.GET("/jobs/:id", deviceJobHandler.Get)
		deviceAPI.POST("/jobs/:id/claim", deviceJobHandler.Claim)
		deviceAPI.POST("/jobs/:id/complete", deviceJobHandler.Complete)
		deviceAPI.POST("/jobs/:id/fail", deviceJobHandler.Fail)
		deviceAPI.POST("/jobs/:id/cancel", deviceJobHandler.Cancel)
	}

	personalSnapshotsAPI := r.Group("/api/personal-snapshots")
	personalSnapshotsAPI.Use(middleware.AuthMiddleware(db, cfg.JWTSecret))
	{
		personalSnapshotsAPI.PUT("/erke", personalSnapshotHandler.PutErke)
		personalSnapshotsAPI.GET("/erke", personalSnapshotHandler.GetErke)
		personalSnapshotsAPI.DELETE("/erke", personalSnapshotHandler.DeleteErke)
	}

	personalDataAccessAPI := r.Group("/api/ai/personal-data-access")
	personalDataAccessAPI.Use(middleware.AuthMiddleware(db, cfg.JWTSecret))
	{
		personalDataAccessAPI.GET("", aiUserPermissionHandler.List)
		personalDataAccessAPI.PUT("", aiUserPermissionHandler.Update)
	}

	// 静态文件服务

	r.GET("/uploads/*filepath", uploadHandler.ServePublic)
	r.HEAD("/uploads/*filepath", uploadHandler.ServePublic)

	// 认证路由

	auth := r.Group("/api")

	{

		auth.POST("/send_code", authHandler.SendVerifyCode)

		auth.POST("/verify_code", authHandler.VerifyCode)

		auth.POST("/register", authHandler.Register)

		auth.POST("/register/email/code", authHandler.RequestEmailRegistrationCode)

		auth.POST("/register/email", authHandler.RegisterWithEmail)

		auth.POST("/login", authHandler.Login)

		auth.POST("/login_edu", authHandler.LoginEdu)

		auth.POST("/register_with_edu", authHandler.RegisterWithEdu)

		auth.POST("/forgot_password", authHandler.ForgotPassword)

		auth.POST("/password/email/code", authHandler.RequestEmailPasswordResetCode)

		auth.POST("/password/email/reset", authHandler.ResetPasswordByEmail)

		auth.POST("/password/edu/reset", authHandler.ForgotPassword)

		auth.POST("/change_password", middleware.AuthMiddleware(db, cfg.JWTSecret), authHandler.ChangePassword)

		auth.POST("/logout", middleware.AuthMiddleware(db, cfg.JWTSecret), authHandler.Logout)

	}

	// 用户路由

	user := r.Group("/api/user")

	user.Use(middleware.AuthMiddleware(db, cfg.JWTSecret))

	{

		user.GET("/profile", userHandler.GetProfile)

		user.PUT("/profile", userHandler.UpdateProfile)

		user.PUT("/avatar", userHandler.UpdateAvatar)

		user.PUT("/background", userHandler.UpdateBackground)

		user.PUT("/nightmode", userHandler.UpdateNightMode)

		user.GET("/account-security", authHandler.GetAccountSecurity)

		user.POST("/email/code", authHandler.RequestUserEmailCode)

		user.PUT("/email", authHandler.UpdateUserEmail)

		user.DELETE("/email", authHandler.DeleteUserEmail)

		user.PUT("/device_token", userHandler.UpdateDeviceToken)
		user.PUT("/push-settings", userHandler.UpdatePushSettings)

		user.POST("/legal-consents", authHandler.AcceptLegalConsents)
		user.POST("/community-rules", authHandler.AcceptCommunityRules)
		user.GET("/privacy/data", privacyHandler.GetMyData)
		user.POST("/privacy/requests", privacyHandler.CreateRequest)
		user.GET("/privacy/requests", privacyHandler.ListMyRequests)
		user.GET("/privacy/export", privacyHandler.ExportMyData)
		user.DELETE("/privacy/consents", privacyHandler.WithdrawConsent)
		user.DELETE("/account", privacyHandler.CancelAccount)
		user.DELETE("/edu-binding", privacyHandler.UnbindEdu)

		user.GET("/invitations", invitationHandler.GetPending)

		user.POST("/invitations/:id/accept", invitationHandler.Accept)

		user.POST("/invitations/:id/reject", invitationHandler.Reject)

		user.GET("/replies/received", replyHandler.GetReceivedList)

		// 旧路径兼容一段时间
		user.GET("/notifications", notificationHandler.GetNotifications)
		user.GET("/notifications/replies/unread", notificationHandler.GetUnreadReplyNotifications)
		user.GET("/notifications/unread_count", notificationHandler.GetUnreadCount)
		user.GET("/notifications/unread-count", notificationHandler.GetUnreadCount)
		user.POST("/notifications/read", notificationHandler.MarkAllRead)
		user.POST("/notifications/read-selected", notificationHandler.MarkSelectedRead)

		user.GET("/competition-calendar", competitionHandler.GetCalendar)
		user.POST("/competition-calendar/init", competitionHandler.InitCalendar)
		user.PUT("/competition-calendar", competitionHandler.UpdateCalendar)
		user.DELETE("/competition-calendar", competitionHandler.DeleteCalendar)
		user.POST("/competition-calendar/items", competitionHandler.CreateCalendarItem)
		user.POST("/competition-calendar/items/copy-from-official/:event_id", competitionHandler.CopyOfficialToCalendar)
		user.PUT("/competition-calendar/items/:id", competitionHandler.UpdateCalendarItem)
		user.DELETE("/competition-calendar/items/:id", competitionHandler.DeleteCalendarItem)
		user.POST("/competition-calendar/items/batch-action", competitionHandler.BatchCalendarItemAction)
		user.POST("/competition-calendar/items/:id/pin", competitionHandler.PinCalendarItem)
		user.POST("/competition-calendar/items/reorder", competitionHandler.ReorderCalendarItems)
		user.POST("/competition-calendar/share", competitionHandler.ShareCalendar)
		user.POST("/competition-calendar/share/:share_code/revoke", competitionHandler.RevokeShare)
		user.POST("/competition-calendar/import-share/preview", competitionHandler.PreviewShareImport)
		user.POST("/competition-calendar/import-share/commit", competitionHandler.CommitShareImport)
		user.POST("/competition-calendar/import-json/preview", competitionHandler.PreviewCalendarJSONImport)
		user.POST("/competition-calendar/import-json/commit", competitionHandler.CommitCalendarJSONImport)
		user.GET("/competitions/state", competitionHandler.GetUserCompetitionState)
		user.GET("/competitions/dashboard", competitionHandler.GetCompetitionDashboard)
		user.GET("/competition-preference", competitionHandler.GetCompetitionPreference)
		user.PUT("/competition-preference", competitionHandler.PutCompetitionPreference)
		user.GET("/competition-capability-profile", competitionHandler.GetCompetitionCapabilityProfile)
		user.GET("/competition-capability-profile/ai-access", competitionHandler.GetCompetitionCapabilityAIAccess)
		user.PUT("/competition-capability-profile/ai-access", competitionHandler.PutCompetitionCapabilityAIAccess)
		user.GET("/competition-awards", competitionHandler.ListCompetitionAwards)
		user.POST("/competition-awards/evidence", competitionHandler.UploadCompetitionAwardEvidence)
		user.POST("/competition-awards", competitionHandler.CreateCompetitionAward)
		user.PUT("/competition-awards/:id", competitionHandler.UpdateCompetitionAward)
		user.DELETE("/competition-awards/:id", competitionHandler.DeleteCompetitionAward)
		user.POST("/competition-awards/:id/submit-verification", competitionHandler.SubmitCompetitionAwardVerification)
		user.POST("/competition-awards/:id/cancel-verification", competitionHandler.CancelCompetitionAwardVerification)
		user.GET("/competition-awards/:id/evidence/:file_id", competitionHandler.DownloadOwnCompetitionAwardEvidence)
		user.GET("/competitions/fit", competitionHandler.ListFitEvents)
		if cfg.CompetitionCandidateEngineV2Enabled {
			user.GET("/competitions/candidates", competitionHandler.ListCompetitionCandidates)
			if cfg.CompetitionAIExplanationEnabled {
				user.POST("/competitions/candidates/explain", competitionHandler.ExplainCompetitionCandidates)
			}
		}
		user.GET("/ai-action-drafts/:id", competitionHandler.GetAIActionDraft)
		user.POST("/ai-action-drafts/:id/confirm", competitionHandler.ConfirmAIActionDraft)
		user.POST("/ai-action-drafts/:id/cancel", competitionHandler.CancelAIActionDraft)
		user.GET("/featured-applications", postHandler.GetMyFeaturedApplications)
		user.GET("/collaboration-applications/sent", postHandler.GetMyCollaborationApplicationsSent)
		user.GET("/collaboration-applications/received", postHandler.GetMyCollaborationApplicationsReceived)
		user.GET("/revision-proposals/sent", postHandler.GetMyRevisionProposalsSent)
		user.GET("/revision-proposals/received", postHandler.GetMyRevisionProposalsReceived)

		user.POST("/checkin", checkinHandler.DoCheckIn)
		user.POST("/checkin/makeup", checkinHandler.DoMakeup)

		user.GET("/checkin/status", checkinHandler.GetStatus)
		user.GET("/checkin/calendar", checkinHandler.GetCalendar)
		user.GET("/checkin/compensations", checkinCompensationHandler.ListMine)
		user.POST("/checkin/compensations/:id/claims", checkinCompensationHandler.Claim)

		user.POST("/:id/follow", userHandler.Follow)
		user.DELETE("/:id/follow", userHandler.Unfollow)
		user.GET("/:id/is-following", userHandler.IsFollowing)
	}

	privacyAdmin := r.Group("/api/admin/privacy")
	privacyAdmin.Use(middleware.AuthMiddleware(db, cfg.JWTSecret), middleware.AdminMiddleware())
	{
		privacyAdmin.GET("/requests", privacyHandler.ListRequestsForAdmin)
		privacyAdmin.PUT("/requests/:id", privacyHandler.HandleRequest)
	}

	userOptional := r.Group("/api/user")
	userOptional.Use(middleware.OptionalAuthMiddleware(db, cfg.JWTSecret))
	{
		userOptional.GET("/:id", userHandler.GetUserInfo)
		userOptional.GET("/:id/following", userHandler.GetFollowing)
		userOptional.GET("/:id/followers", userHandler.GetFollowers)
		userOptional.GET("/:id/posts/count", userHandler.GetUserPostCount)
		userOptional.GET("/:id/posts", userHandler.GetUserPosts)
		userOptional.GET("/:id/market-posts", userHandler.GetUserMarketPosts)
	}

	internalMCP := r.Group("/internal/mcp")
	internalMCP.Use(handlers.InternalMCPGrantMiddleware(cfg.SyluliveMCPGrant))
	{
		internalMCP.POST("/competition/search", competitionHandler.InternalMCPCompetitionSearch)
		internalMCP.POST("/competition/details", competitionHandler.InternalMCPCompetitionDetails)
		internalMCP.POST("/competition/compare", competitionHandler.InternalMCPCompetitionCompare)
		internalMCP.POST("/competition/candidate-context", competitionHandler.InternalMCPCompetitionCandidateContext)
		internalMCP.POST("/competition/verify-records", competitionHandler.InternalMCPCompetitionVerifyRecords)
	}

	r.GET("/api/notifications", middleware.AuthMiddleware(db, cfg.JWTSecret), notificationHandler.GetNotifications)
	r.GET("/api/notifications/replies/unread", middleware.AuthMiddleware(db, cfg.JWTSecret), notificationHandler.GetUnreadReplyNotifications)
	r.GET("/api/notifications/unread-count", middleware.AuthMiddleware(db, cfg.JWTSecret), notificationHandler.GetUnreadCount)
	r.GET("/api/notifications/unread_count", middleware.AuthMiddleware(db, cfg.JWTSecret), notificationHandler.GetUnreadCount) // keep for backwards compatibility just in case
	r.POST("/api/notifications/read", middleware.AuthMiddleware(db, cfg.JWTSecret), notificationHandler.MarkAllRead)
	r.POST("/api/notifications/read-selected", middleware.AuthMiddleware(db, cfg.JWTSecret), notificationHandler.MarkSelectedRead)

	// 帖子路由

	posts := r.Group("/api/posts")

	posts.Use(middleware.OptionalAuthMiddleware(db, cfg.JWTSecret))

	{

		posts.GET("", postHandler.GetList)

		posts.GET("/featured", postHandler.GetFeaturedList)

		posts.GET("/:id", postHandler.GetOne)

		posts.GET("/:id/replies", replyHandler.GetList)

		posts.GET("/:id/replies/:replyId/children", replyHandler.GetChildren)

		posts.GET("/:id/replies/:replyId/context", replyHandler.GetReplyContext)

	}

	r.GET("/api/search", middleware.OptionalAuthMiddleware(db, cfg.JWTSecret), searchHandler.Search)

	// 水帖版块读取接口（公开，可选鉴权）
	waterPublic := r.Group("/api/water/sections")
	waterPublic.Use(middleware.OptionalAuthMiddleware(db, cfg.JWTSecret))
	{
		waterPublic.GET("", waterSectionHandler.List)
		waterPublic.GET("/:slug", waterSectionHandler.Get)
		waterPublic.GET("/:slug/level-titles", waterSectionHandler.GetLevelTitles)
	}

	// 水帖版块关注相关（需要登录）
	waterFollow := r.Group("/api/water/sections")
	waterFollow.Use(middleware.AuthMiddleware(db, cfg.JWTSecret))
	{
		// 注意: /followed 必须在 /:slug 之前以防冲突
		waterFollow.GET("/followed", waterSectionHandler.GetFollowedSections)
		waterFollow.GET("/:slug/my-level", waterSectionHandler.GetMyLevel)
		waterFollow.POST("/:slug/follow", waterSectionHandler.Follow)
		waterFollow.DELETE("/:slug/follow", waterSectionHandler.Unfollow)
		waterFollow.GET("/:slug/my-permission", waterModeratorHandler.MyPermission)
	}

	// 水帖版主管理接口（仅 admin/super_admin）
	adminWater := r.Group("/api/admin/water/sections/:slug/moderators")
	adminWater.Use(middleware.AuthMiddleware(db, cfg.JWTSecret), middleware.AdminMiddleware())
	{
		adminWater.GET("", waterModeratorHandler.GetModerators)
		adminWater.POST("", waterModeratorHandler.AssignModerator)
		adminWater.PATCH("/:moderator_id", waterModeratorHandler.UpdateModerator)
		adminWater.DELETE("/:moderator_id", waterModeratorHandler.RevokeModerator)
	}

	adminWaterReviews := r.Group("/api/admin/water/section-icon-reviews")
	adminWaterReviews.Use(middleware.AuthMiddleware(db, cfg.JWTSecret), middleware.AdminMiddleware())
	{
		adminWaterReviews.GET("", waterSectionHandler.AdminListSectionIconReviews)
		adminWaterReviews.POST("/:id/approve", waterSectionHandler.AdminApproveSectionIconReview)
		adminWaterReviews.POST("/:id/reject", waterSectionHandler.AdminRejectSectionIconReview)
	}

	// 水帖版块内容管理接口（登录后，权限由 handler 内部判断）
	waterMod := r.Group("/api/water/sections/:slug")
	waterMod.Use(middleware.AuthMiddleware(db, cfg.JWTSecret))
	{
		waterMod.PATCH("", waterSectionHandler.Update)
		waterMod.PATCH("/level-titles", waterSectionHandler.UpdateLevelTitles)
		waterMod.POST("/tags", waterSectionHandler.CreateTag)
		waterMod.PATCH("/tags/:tag_id/status", waterSectionHandler.UpdateTagStatus)
		waterMod.PATCH("/tags/:tag_id", waterSectionHandler.UpdateTag)
		waterMod.POST("/posts/:post_id/pin", waterModerationHandler.PinPost)
		waterMod.DELETE("/posts/:post_id/pin", waterModerationHandler.UnpinPost)
		waterMod.POST("/posts/:post_id/feature", waterModerationHandler.FeaturePost)
		waterMod.DELETE("/posts/:post_id/feature", waterModerationHandler.UnfeaturePost)
		waterMod.DELETE("/posts/:post_id/moderate", waterModerationHandler.DeletePost)
		waterMod.POST("/posts/:post_id/restore", waterModerationHandler.RestorePost)
		waterMod.POST("/users/:user_id/mute", waterModerationHandler.MuteUser)
		waterMod.DELETE("/users/:user_id/mute", waterModerationHandler.UnmuteUser)
		waterMod.GET("/mutes", waterModerationHandler.ListMutes)
		waterMod.GET("/moderation/logs", waterModerationHandler.ListLogs)

		waterMod.POST("/icon-review", waterSectionHandler.SubmitSectionIconReview)
		waterMod.GET("/icon-review/current", waterSectionHandler.GetCurrentSectionIconReview)
		waterMod.POST("/icon-review/:id/cancel", waterSectionHandler.CancelSectionIconReview)
	}

	r.POST("/api/collaboration-applications/:id/approve", middleware.AuthMiddleware(db, cfg.JWTSecret), postHandler.ApproveCollaborationApplication)
	r.POST("/api/collaboration-applications/:id/reject", middleware.AuthMiddleware(db, cfg.JWTSecret), postHandler.RejectCollaborationApplication)
	r.POST("/api/revision-proposals/:id/approve", middleware.AuthMiddleware(db, cfg.JWTSecret), postHandler.ApproveRevisionProposal)
	r.POST("/api/revision-proposals/:id/reject", middleware.AuthMiddleware(db, cfg.JWTSecret), postHandler.RejectRevisionProposal)

	waterTeam := r.Group("/api/water/team")
	waterTeam.Use(middleware.AuthMiddleware(db, cfg.JWTSecret))
	{
		waterTeam.POST("/recruitments/:id/apply", waterTeamHandler.Apply)
		waterTeam.GET("/recruitments/:id/applications", waterTeamHandler.GetRecruitmentApplications)
		waterTeam.POST("/applications/:id/accept", waterTeamHandler.Accept)
		waterTeam.POST("/applications/:id/reject", waterTeamHandler.Reject)
		waterTeam.POST("/applications/:id/cancel", waterTeamHandler.Cancel)
		waterTeam.POST("/applications/:id/leave", waterTeamHandler.Leave)
		waterTeam.POST("/applications/:id/remove", waterTeamHandler.Remove)
		waterTeam.GET("/my_applications", waterTeamHandler.GetMyApplications)
		waterTeam.PATCH("/recruitments/:id/status", waterTeamHandler.UpdateRecruitmentStatus)
	}

	// 独立组队 API — /api/team/...
	teamAuth := r.Group("/api/team")
	teamAuth.Use(middleware.AuthMiddleware(db, cfg.JWTSecret))
	{
		teamAuth.POST("/recruitments", waterTeamHandler.CreateTeamRecruitment)
		teamAuth.PATCH("/recruitments/:id", waterTeamHandler.UpdateTeamRecruitment)
		teamAuth.DELETE("/recruitments/:id", waterTeamHandler.DeleteTeamRecruitment)
		teamAuth.GET("/recruitments/mine", waterTeamHandler.GetMyTeamRecruitments)

		// 申请相关（复用旧 Handler 方法）
		teamAuth.POST("/recruitments/:id/apply", waterTeamHandler.Apply)
		teamAuth.GET("/recruitments/:id/applications", waterTeamHandler.GetRecruitmentApplications)
		teamAuth.POST("/applications/:id/accept", waterTeamHandler.Accept)
		teamAuth.POST("/applications/:id/reject", waterTeamHandler.Reject)
		teamAuth.POST("/applications/:id/cancel", waterTeamHandler.Cancel)
		teamAuth.POST("/applications/:id/leave", waterTeamHandler.Leave)
		teamAuth.POST("/applications/:id/remove", waterTeamHandler.Remove)

		teamAuth.GET("/my_applications", waterTeamHandler.GetMyApplications)
		teamAuth.PATCH("/recruitments/:id/status", waterTeamHandler.UpdateRecruitmentStatus)
	}
	teamPublic := r.Group("/api/team")
	{
		// 静态 mine 路由须先注册，避免与 :id 参数路由冲突。
		// 公开读取使用可选鉴权，以便返回登录用户专属状态。
		teamPublic.GET("/recruitments", middleware.OptionalAuthMiddleware(db, cfg.JWTSecret), waterTeamHandler.ListTeamRecruitments)
		teamPublic.GET("/recruitments/:id", middleware.OptionalAuthMiddleware(db, cfg.JWTSecret), waterTeamHandler.GetTeamRecruitment)
	}

	competitions := r.Group("/api/competitions")
	{
		competitions.GET("/categories", competitionHandler.GetCategories)
		competitions.GET("/overview", competitionHandler.GetOverview)
		competitions.GET("/events", competitionHandler.ListEvents)
		competitions.GET("/events/:id", competitionHandler.GetEvent)
	}

	// 投票公开读取使用可选鉴权，以返回当前用户的选择和结果权限。
	pollsPublic := r.Group("/api/polls")
	pollsPublic.Use(middleware.OptionalAuthMiddleware(db, cfg.JWTSecret))
	{
		pollsPublic.GET("", pollHandler.List)
		pollsPublic.GET("/:id", pollHandler.Get)
	}

	pollsAuth := r.Group("/api/polls")
	pollsAuth.Use(middleware.AuthMiddleware(db, cfg.JWTSecret))
	{
		pollsAuth.POST("", pollHandler.Create)
		pollsAuth.PUT("/:id", pollHandler.Update)
		pollsAuth.DELETE("/:id", pollHandler.Delete)
		pollsAuth.PUT("/:id/ballot", pollHandler.PutBallot)
		pollsAuth.POST("/:id/close", pollHandler.Close)
	}
	r.GET("/api/me/polls", middleware.AuthMiddleware(db, cfg.JWTSecret), pollHandler.ListMine)

	postsAuth := r.Group("/api/posts")

	postsAuth.Use(middleware.AuthMiddleware(db, cfg.JWTSecret))

	{

		postsAuth.POST("", postHandler.Create)

		postsAuth.PUT("/:id", postHandler.Update)

		postsAuth.PATCH("/:id/status", postHandler.UpdateStatus)

		postsAuth.DELETE("/:id", postHandler.Delete)

		postsAuth.POST("/:id/featured-applications", postHandler.CreateFeaturedApplication)
		postsAuth.GET("/:id/featured-application-status", postHandler.GetFeaturedApplicationStatus)
		postsAuth.POST("/:id/collaboration-applications", postHandler.CreateCollaborationApplication)
		postsAuth.POST("/:id/revision-proposals", postHandler.CreateRevisionProposal)

		postsAuth.POST("/:id/replies", replyHandler.Create)

		postsAuth.POST("/:id/appeal", appealHandler.Create)

		postsAuth.GET("/:id/notifications/unread", notificationHandler.GetPostUnreadReplyNotifications)

	}

	// 回复路由（带认证）

	replies := r.Group("/api/replies")

	replies.Use(middleware.AuthMiddleware(db, cfg.JWTSecret))

	{

		replies.DELETE("/:id", replyHandler.Delete)

		replies.GET("/me", replyHandler.GetMeList)

	}

	// 点赞路由

	like := r.Group("/api")

	like.Use(middleware.AuthMiddleware(db, cfg.JWTSecret))

	{

		like.POST("/posts/:id/like", likeHandler.LikePost)

		like.DELETE("/posts/:id/like", likeHandler.UnlikePost)

		like.POST("/replies/:id/like", likeHandler.LikeReply)

		like.DELETE("/replies/:id/like", likeHandler.UnlikeReply)

	}

	// Feed 推荐路由（FEED-1 用户控制 + FEED-2 行为事件采集）

	feed := r.Group("/api/feed")

	feed.Use(middleware.AuthMiddleware(db, cfg.JWTSecret))

	{
		feed.PUT("/posts/:post_id/not-interested", feedHandler.MarkNotInterested)
		feed.DELETE("/posts/:post_id/not-interested", feedHandler.UndoNotInterested)
		feed.PUT("/authors/:author_id/hidden", feedHandler.HideAuthor)
		feed.DELETE("/authors/:author_id/hidden", feedHandler.RestoreAuthor)
		feed.GET("/hidden-authors", feedHandler.GetHiddenAuthors)

		feed.POST("/events/batch", feedEventHandler.RecordEventsBatch)
	}

	// 私信路由

	messages := r.Group("/api/messages")

	messages.Use(middleware.AuthMiddleware(db, cfg.JWTSecret))

	{

		messages.GET("/conversations", messageHandler.GetConversations)

		messages.GET("/events", messageHandler.Events)

		messages.GET("/files/:file_id", messageHandler.ServePrivateFile)

		messages.GET("/users/:target_user_id/conversation", messageHandler.GetConversationWithUser)

		messages.GET("/conversations/:id", messageHandler.GetMessages)

		messages.GET("/:user_id/send-state", messageHandler.GetSendState)

		messages.POST("/:user_id", messageHandler.Send)

		messages.POST("/conversations/:id/read", messageHandler.MarkRead)

		messages.GET("/unread_count", messageHandler.GetUnreadCount)

	}

	// 账号级自定义表情收藏路由。
	emojiFavorites := r.Group("/api/emoji/favorites")
	emojiFavorites.Use(middleware.AuthMiddleware(db, cfg.JWTSecret))
	{
		emojiFavorites.GET("", emojiFavoriteHandler.List)
		emojiFavorites.POST("", emojiFavoriteHandler.Create)
		emojiFavorites.POST("/from-message", emojiFavoriteHandler.CreateFromMessage)
		emojiFavorites.POST("/from-public-image", emojiFavoriteHandler.CreateFromPublicImage)
		emojiFavorites.GET("/:id/file", emojiFavoriteHandler.ServeFile)
		emojiFavorites.GET("/:id/thumbnail", emojiFavoriteHandler.ServeThumbnail)
		emojiFavorites.DELETE("/:id", emojiFavoriteHandler.Delete)
	}

	// 公告路由：/api/announcements 与 /api/notices 为同一资源别名，
	// 注册逻辑见 announcement_routes.go。
	registerAnnouncementRoutes(r, announcementHandler, db, cfg)

	// 举报路由

	reports := r.Group("/api/reports")

	reports.Use(middleware.AuthMiddleware(db, cfg.JWTSecret))

	{

		reports.POST("", reportHandler.Create)

	}

	reportsAdmin := reports.Group("")

	reportsAdmin.Use(middleware.AdminMiddleware())

	{

		reportsAdmin.GET("", reportHandler.GetList)

		reportsAdmin.PUT("/:id/handle", reportHandler.Handle)

	}

	// 申诉路由

	appeals := r.Group("/api/appeals")

	appeals.Use(middleware.AuthMiddleware(db, cfg.JWTSecret))

	{

		appeals.POST("/post/:id", appealHandler.Create)

		appeals.GET("", appealHandler.GetList)

		appeals.GET("/:id", appealHandler.GetOne)

		appeals.POST("/:id/vote", appealHandler.Vote)

	}

	// 试卷库路由：统一登录校验，普通用户由处理器继续校验教务认证。
	examPapers := r.Group("/api/exam-papers")
	examPapers.Use(middleware.AuthMiddleware(db, cfg.JWTSecret))
	{
		examPapers.GET("", examPaperHandler.List)
		examPapers.GET("/my-submissions", examPaperHandler.MySubmissions)
		examPapers.DELETE("/my-submissions/:id", examPaperHandler.Withdraw)
		examPapers.POST("/upload-sessions", examPaperHandler.CreateUploadSession)
		examPapers.POST("/upload-sessions/:id/complete", examPaperHandler.CompleteUploadSession)
		examPapers.GET("/:id", examPaperHandler.Get)
		examPapers.POST("", examPaperHandler.Upload)
		examPapers.GET("/:id/preview", examPaperHandler.Preview)
		examPapers.GET("/:id/download", examPaperHandler.Download)
	}
	// 管理员邀请路由

	admin := r.Group("/api/admin")

	admin.Use(middleware.AuthMiddleware(db, cfg.JWTSecret), middleware.AdminMiddleware())

	{

		admin.GET("/exam-papers", examPaperHandler.AdminList)
		admin.GET("/exam-papers/pending-count", examPaperHandler.AdminPendingCount)
		admin.GET("/exam-papers/:id", examPaperHandler.AdminGet)
		admin.POST("/exam-papers/:id/approve", examPaperHandler.AdminApprove)
		admin.POST("/exam-papers/:id/reject", examPaperHandler.AdminReject)
		admin.PATCH("/exam-papers/:id", examPaperHandler.AdminUpdate)
		admin.POST("/exam-papers/:id/unpublish", examPaperHandler.AdminUnpublish)
		admin.GET("/candidates", invitationHandler.GetCandidates)
		admin.GET("/candidates/stats", invitationHandler.GetCandidatesStats)

		admin.GET("/feed/metrics", feedMetricsHandler.AdminMetrics)
		admin.GET("/feed/metrics/baseline", feedMetricsHandler.AdminBaseline)

		admin.GET("/members", invitationHandler.GetMembers)

		admin.POST("/invite/:user_id", invitationHandler.Create)

		admin.GET("/invitations/pending", invitationHandler.GetApprovalList)

		admin.POST("/invitations/:id/vote", invitationHandler.VoteApprove)

		admin.GET("/removals/pending", teacherHandler.GetRemovalRequests)

		admin.GET("/featured-applications", postHandler.AdminGetFeaturedApplications)
		admin.POST("/featured-applications/:id/approve", postHandler.AdminApproveFeaturedApplication)
		admin.POST("/featured-applications/:id/reject", postHandler.AdminRejectFeaturedApplication)
		admin.GET("/posts/pinned", postHandler.AdminGetPinnedPosts)
		admin.POST("/posts/:id/pin", postHandler.AdminPinPost)
		admin.POST("/posts/:id/unpin", postHandler.AdminUnpinPost)
		admin.POST("/posts/:id/unfeature", postHandler.AdminUnfeaturePost)
		admin.POST("/competitions/categories", competitionHandler.AdminCreateCategory)
		admin.PUT("/competitions/categories/:id", competitionHandler.AdminUpdateCategory)
		admin.DELETE("/competitions/categories/:id", competitionHandler.AdminDeleteCategory)
		admin.GET("/competitions/events", competitionHandler.AdminListEvents)
		admin.GET("/competitions/audience-options", competitionHandler.AdminCompetitionAudienceOptions)
		admin.GET("/competitions/overview", competitionHandler.AdminGetEventsOverview)
		admin.POST("/competitions/events/batch-action", competitionHandler.AdminBatchAction)
		admin.POST("/competitions/events", competitionHandler.AdminCreateEvent)
		admin.PUT("/competitions/events/:id", competitionHandler.AdminUpdateEvent)
		admin.DELETE("/competitions/events/:id", competitionHandler.AdminDeleteEvent)
		admin.POST("/competitions/events/:id/archive", competitionHandler.AdminArchiveEvent)
		admin.POST("/competitions/events/:id/publish", competitionHandler.AdminPublishEvent)
		admin.POST("/competitions/events/:id/restore", competitionHandler.AdminRestoreEvent)
		admin.POST("/competitions/events/:id/verify", competitionHandler.AdminVerifyEvent)
		admin.POST("/competitions/import-json/preview", competitionHandler.AdminImportJSONPreview)
		admin.POST("/competitions/import-json/commit", competitionHandler.AdminImportJSONCommit)
		if cfg.CompetitionCatalogV2Enabled {
			admin.POST("/competition-catalog/baseline/export", competitionHandler.AdminExportCompetitionCatalogBaseline)
			admin.POST("/competition-catalog/baseline/export-identity", competitionHandler.AdminExportCompetitionCatalogIdentityBaseline)
			admin.POST("/competition-catalog/packages/validate", competitionHandler.AdminValidateCompetitionCatalog)
			admin.POST("/competition-catalog/packages/import", competitionHandler.AdminImportCompetitionCatalog)
			admin.GET("/competition-catalog/packages", competitionHandler.AdminListCompetitionCatalogPackages)
			admin.GET("/competition-catalog/legacy-resolutions", competitionHandler.AdminListCompetitionLegacyResolutions)
			admin.GET("/competition-catalog/packages/:id", competitionHandler.AdminGetCompetitionCatalogPackage)
			admin.GET("/competition-catalog/packages/:id/diff", competitionHandler.AdminDiffCompetitionCatalogPackage)
			admin.POST("/competition-catalog/packages/:id/mappings/suggest", competitionHandler.AdminSuggestCompetitionCatalogLegacyMappings)
			admin.GET("/competition-catalog/packages/:id/mappings", competitionHandler.AdminListCompetitionCatalogLegacyMappings)
			admin.PUT("/competition-catalog/packages/:id/mappings/:mapping_id", competitionHandler.AdminReviewCompetitionCatalogLegacyMapping)
			admin.POST("/competition-catalog/packages/:id/mappings/batch-confirm", competitionHandler.AdminBatchConfirmCompetitionCatalogLegacyMappings)
			admin.POST("/competition-catalog/packages/:id/mappings/inherit", competitionHandler.AdminInheritCompetitionCatalogLegacyMappings)
			admin.POST("/competition-catalog/packages/:id/preflight", competitionHandler.AdminPreflightCompetitionCatalog)
			admin.POST("/competition-catalog/packages/:id/activate", competitionHandler.AdminActivateCompetitionCatalog)
			admin.POST("/competition-catalog/packages/:id/rollback", competitionHandler.AdminRollbackCompetitionCatalog)
		}
		admin.GET("/competitions/import-batches", competitionHandler.AdminListImportBatches)
		admin.GET("/competitions/import-batches/:batch_id", competitionHandler.AdminGetImportBatch)
		admin.GET("/competitions/share-snapshots", competitionHandler.AdminListShareSnapshots)
		admin.POST("/competitions/share-snapshots/:id/disable", competitionHandler.AdminDisableShareSnapshot)
		admin.POST("/competitions/share-snapshots/:id/restore", competitionHandler.AdminRestoreShareSnapshot)

	}

	adminSuper := r.Group("/api/admin")

	adminSuper.Use(middleware.AuthMiddleware(db, cfg.JWTSecret), middleware.SuperAdminMiddleware())

	{

		adminSuper.POST("/promote", invitationHandler.DirectPromote)
		adminSuper.GET("/competition-awards/verifications", competitionHandler.ListCompetitionAwardVerifications)
		adminSuper.GET("/competition-awards/verifications/:id", competitionHandler.GetCompetitionAwardVerification)
		adminSuper.POST("/competition-awards/verifications/:id/approve", competitionHandler.ApproveCompetitionAwardVerification)
		adminSuper.POST("/competition-awards/verifications/:id/reject", competitionHandler.RejectCompetitionAwardVerification)
		adminSuper.GET("/competition-awards/verifications/:id/evidence/:file_id", competitionHandler.DownloadAdminCompetitionAwardEvidence)

	}

	// 上传路由

	r.POST("/api/upload", middleware.AuthMiddleware(db, cfg.JWTSecret), uploadHandler.Upload)

	r.POST("/api/upload_multiple", middleware.AuthMiddleware(db, cfg.JWTSecret), uploadHandler.UploadMultiple)

	// 教务系统路由

	edu := r.Group("/api/edu")

	{

		edu.GET("/status", middleware.AuthMiddleware(db, cfg.JWTSecret), eduHandler.GetEduStatus)

		edu.POST("/bind", middleware.AuthMiddleware(db, cfg.JWTSecret), eduHandler.BindEdu)

		edu.DELETE("/bind", middleware.AuthMiddleware(db, cfg.JWTSecret), eduHandler.UnbindEdu)

		edu.POST("/session/logout", middleware.AuthMiddleware(db, cfg.JWTSecret), eduHandler.LogoutEduSession)

		edu.POST("/session/resume", middleware.AuthMiddleware(db, cfg.JWTSecret), eduHandler.ResumeEduSession)

		edu.DELETE("/authorization", middleware.AuthMiddleware(db, cfg.JWTSecret), eduHandler.RevokeEduAuthorization)

		edu.POST("/courses", middleware.AuthMiddleware(db, cfg.JWTSecret), eduHandler.GetCourses)

		// 保留旧路径仅用于返回明确的客户端升级提示，绝不再代理服务端课表缓存。
		edu.GET("/courses/local", middleware.AuthMiddleware(db, cfg.JWTSecret), eduHandler.RetiredCourseCache)

		edu.POST("/courses/sync", middleware.AuthMiddleware(db, cfg.JWTSecret), eduHandler.RetiredCourseCache)

		edu.POST("/grades", middleware.AuthMiddleware(db, cfg.JWTSecret), eduHandler.GetGrades)

		edu.POST("/grades/detail", middleware.AuthMiddleware(db, cfg.JWTSecret), eduHandler.GetGradeDetail)

		edu.POST("/academic-situation", middleware.AuthMiddleware(db, cfg.JWTSecret), eduHandler.GetAcademicSituation)

		edu.POST("/credit-requirements", middleware.AuthMiddleware(db, cfg.JWTSecret), eduHandler.GetCreditRequirements)

		edu.POST("/pre_verify", eduHandler.PreVerify) // 注册前验证教务账号

	}

	// 超级管理员路由

	superAdmin := r.Group("/api/super")

	superAdmin.Use(middleware.AuthMiddleware(db, cfg.JWTSecret), middleware.SuperAdminMiddleware())

	{

		superAdmin.GET("/users", superAdminHandler.GetUsers)
		superAdmin.POST("/lottery", superAdminHandler.CreateLotteryEvent)
		superAdmin.DELETE("/lottery/:id", superAdminHandler.DeleteLotteryEvent)
		superAdmin.GET("/lottery/participants", superAdminHandler.GetLotteryParticipants)
		superAdmin.DELETE("/lottery/participants/:event_id/:user_id", superAdminHandler.KickLotteryParticipant)

		superAdmin.PUT("/users/:id/role", superAdminHandler.UpdateUserRole)
		superAdmin.PUT("/users/:id/credit", superAdminHandler.UpdateUserCredit)

		superAdmin.POST("/users/:id/reset_password", superAdminHandler.ResetUserPassword)

		superAdmin.DELETE("/users/:id", superAdminHandler.DeleteUser)

		superAdmin.GET("/stats", superAdminHandler.GetStatistics)

		superAdmin.GET("/admin_logs", superAdminHandler.GetAdminLogs)

		superAdmin.POST("/admin_logs/revoke_exp", superAdminHandler.RevokeAdminExp)
		superAdmin.GET("/app-releases", appUpdateHandler.AdminList)
		superAdmin.GET("/app-releases/:id", appUpdateHandler.AdminGet)
		superAdmin.POST("/app-releases", appUpdateHandler.AdminCreate)
		superAdmin.PATCH("/app-releases/:id", appUpdateHandler.AdminUpdate)
		superAdmin.POST("/app-releases/:id/publish", appUpdateHandler.AdminPublish)
		superAdmin.POST("/app-releases/:id/withdraw", appUpdateHandler.AdminWithdraw)
		superAdmin.DELETE("/app-releases/:id", appUpdateHandler.AdminDeleteDraft)
		superAdmin.POST("/checkin/users/:id/rebuild", checkinHandler.RebuildUserStats)
		superAdmin.GET("/checkin/compensations", checkinCompensationHandler.ListCampaigns)
		superAdmin.POST("/checkin/compensations", checkinCompensationHandler.Publish)
		superAdmin.POST("/checkin/compensations/:id/close", checkinCompensationHandler.Close)

		superAdmin.GET("/invitations/pending", invitationHandler.GetApprovalList)

		superAdmin.POST("/invitations/:id/approve", invitationHandler.Approve)
	}

	// 二课查询路由

	r.POST("/api/erke/scores", middleware.AuthMiddleware(db, cfg.JWTSecret), erkeHandler.GetScores)

	// 用户反馈路由

	r.POST("/api/feedback", middleware.OptionalAuthMiddleware(db, cfg.JWTSecret), feedbackHandler.Submit)

	// 教程页面路由（公开读，管理员写）

	tutorialHandler := handlers.NewTutorialHandler(db)
	r.GET("/api/tutorial/:key", tutorialHandler.Get)

	r.PUT("/api/tutorial/:key", middleware.AuthMiddleware(db, cfg.JWTSecret), middleware.AdminMiddleware(), tutorialHandler.Update)

	// 避雷版块 - 教师路由

	teacher := r.Group("/api/teachers")

	{

		teacher.GET("", teacherHandler.GetList)

	}

	teacherAdmin := teacher.Group("")

	teacherAdmin.Use(middleware.AuthMiddleware(db, cfg.JWTSecret), middleware.AdminMiddleware())

	{

		teacherAdmin.GET("/pending", teacherHandler.GetPending)

		teacherAdmin.GET("/logs", teacherHandler.GetLogs)

		teacherAdmin.PUT("/:id/verify", teacherHandler.Verify)

		teacherAdmin.DELETE("/:id/reject", teacherHandler.RejectTeacher)

	}

	teacherAuth := teacher.Group("")

	teacherAuth.Use(middleware.AuthMiddleware(db, cfg.JWTSecret))

	{

		teacherAuth.GET("/:id", teacherHandler.GetDetail)

		teacherAuth.POST("", teacherHandler.Create)

		teacherAuth.POST("/:id/rate", teacherHandler.Rate)

		teacherAuth.DELETE("/rating/:id", teacherHandler.DeleteRating)

		teacherAuth.PUT("/ratings/:id/vote", teacherHandler.VoteRating)

		teacherAuth.POST("/rating/:id/report", teacherHandler.ReportRating)

	}

	teacherAdminVotes := teacher.Group("")

	teacherAdminVotes.Use(middleware.AuthMiddleware(db, cfg.JWTSecret), middleware.AdminMiddleware())

	{

		teacherAdminVotes.POST("/admin/:id/vote-remove", teacherHandler.VoteRemoveAdmin)

		teacherAdminVotes.GET("/admin/:id/votes", teacherHandler.GetAdminVotes)

	}

	// 专业榜路由

	major := r.Group("/api/majors")

	{

		major.GET("", majorHandler.GetList)

	}

	majorAdmin := major.Group("")

	majorAdmin.Use(middleware.AuthMiddleware(db, cfg.JWTSecret), middleware.AdminMiddleware())

	{

		majorAdmin.GET("/pending", majorHandler.GetPending)

		majorAdmin.PUT("/:id/verify", majorHandler.Verify)

		majorAdmin.DELETE("/:id/reject", majorHandler.Reject)

		majorAdmin.DELETE("/:id", majorHandler.DeleteMajor)

	}

	majorAuth := major.Group("")

	majorAuth.Use(middleware.AuthMiddleware(db, cfg.JWTSecret))

	{

		majorAuth.GET("/:id", majorHandler.GetDetail)

		majorAuth.POST("", majorHandler.Create)

		majorAuth.POST("/:id/rate", majorHandler.Rate)

		majorAuth.DELETE("/rating/:id", majorHandler.DeleteRating)

		majorAuth.PUT("/ratings/:id/vote", majorHandler.VoteRating)

	}

	// 食堂榜路由

	canteen := r.Group("/api/canteens")

	{

		canteen.GET("", canteenHandler.GetList)

		// 食堂发现/排行聚合接口（公开）：
		// /home 与 /rankings 是静态段，优先于 /:id 注册避免歧义。
		canteen.GET("/home", canteenHandler.GetHome)
		canteen.GET("/rankings", canteenHandler.GetRankings)

		// 食堂详情属于公开内容；存在有效登录态时附带“我的评价/投票”状态。
		canteen.GET("/:id", middleware.OptionalAuthMiddleware(db, cfg.JWTSecret), canteenHandler.GetDetail)

		// 菜品图库公开接口
		canteen.GET("/:id/dishes", canteenDishHandler.ListDishes)
		canteen.GET("/:id/dishes/:dishId", canteenDishHandler.GetDish)
		canteen.GET("/:id/reviews", canteenHandler.GetReviews)
		canteen.GET("/:id/reviews/history/:userId", canteenHandler.GetReviewHistory)
		canteen.GET("/:id/reviewers/:userId/history", canteenHandler.GetReviewHistory)
		canteen.GET("/:id/dish-suggestions", canteenHandler.GetDishSuggestions)
		canteen.GET("/dishes/:dishId/reviews", canteenHandler.GetDishReviews)

	}

	canteenAdmin := canteen.Group("")

	canteenAdmin.Use(middleware.AuthMiddleware(db, cfg.JWTSecret), middleware.AdminMiddleware())

	{

		canteenAdmin.GET("/pending", canteenHandler.AdminListPending)

		canteenAdmin.POST("/:id/approve", canteenHandler.ApproveCanteen)

		canteenAdmin.POST("/:id/offline", canteenHandler.OfflineCanteen)
		canteenAdmin.POST("/:id/online", canteenHandler.OnlineCanteen)

		canteenAdmin.DELETE("/:id/pending", canteenHandler.RejectCanteen)

		canteenAdmin.DELETE("/:id", canteenHandler.DeleteCanteen)

		canteenAdmin.PUT("/:id/image", canteenHandler.UpdateImage)

		// 菜品实拍审核与菜品管理
		canteenAdmin.GET("/dish-photos/pending", canteenDishPhotoAdminHandler.AdminListPendingDishPhotos)
		canteenAdmin.GET("/dish-photos/:photoId", canteenDishPhotoAdminHandler.AdminGetDishPhotoDetail)
		canteenAdmin.POST("/dish-photos/:photoId/approve", canteenDishPhotoAdminHandler.ApproveDishPhoto)
		canteenAdmin.POST("/dish-photos/:photoId/reject", canteenDishPhotoAdminHandler.RejectDishPhoto)
		canteenAdmin.POST("/dish-photos/:photoId/archive", canteenDishPhotoAdminHandler.ArchiveDishPhoto)
		canteenAdmin.PATCH("/dishes/:dishId", canteenDishPhotoAdminHandler.AdminUpdateDish)
		canteenAdmin.POST("/dishes/:dishId/merge", canteenDishPhotoAdminHandler.AdminMergeDish)

	}

	canteenAuth := canteen.Group("")

	canteenAuth.Use(middleware.AuthMiddleware(db, cfg.JWTSecret))

	{

		canteenAuth.POST("", canteenHandler.Create)

		canteenAuth.POST("/:id/rate", canteenHandler.Rate)
		canteenAuth.POST("/:id/reviews", canteenHandler.CreateReview)
		canteenAuth.PATCH("/reviews/:reviewId", canteenHandler.UpdateReview)
		canteenAuth.POST("/dishes/:dishId/reviews", canteenHandler.CreateDishReview)

		canteenAuth.PUT("/ratings/:ratingId/vote", canteenHandler.VoteRating)

		// 学生上传菜品实拍
		canteenAuth.POST("/:id/dish-photos", canteenDishPhotoHandler.SubmitDishPhoto)
		canteenAuth.POST("/:id/dish-submissions", canteenDishPhotoHandler.SubmitDishPhotoV2)

	}

	// 评价编辑的语义化别名，供新客户端按计划文档使用；旧 /canteens/reviews/:reviewId 保留。
	canteenReviewAuth := r.Group("/api/canteen-reviews")
	canteenReviewAuth.Use(middleware.AuthMiddleware(db, cfg.JWTSecret))
	canteenReviewAuth.PATCH("/:reviewId", canteenHandler.UpdateReview)

	// 违规管理

	violation := r.Group("/api/violations")

	violation.Use(middleware.AuthMiddleware(db, cfg.JWTSecret))

	{

		violation.GET("", teacherHandler.GetViolations)

		violation.POST("/:id/appeal", teacherHandler.AppealViolation)

	}

	violationAdmin := violation.Group("")

	violationAdmin.Use(middleware.AdminMiddleware())

	{

		violationAdmin.POST("", teacherHandler.AddViolation)

		violationAdmin.PUT("/:id/appeal", teacherHandler.HandleAppeal)

	}

	// 管理员违规列表使用独立资源路径，普通用户接口永远只返回当前用户记录。
	adminViolations := r.Group("/api/admin/violations")
	adminViolations.Use(middleware.AuthMiddleware(db, cfg.JWTSecret), middleware.AdminMiddleware())
	{
		adminViolations.GET("", teacherHandler.GetAdminViolations)
		adminViolations.POST("", teacherHandler.AddViolation)
		adminViolations.PUT("/:id/appeal", teacherHandler.HandleAppeal)
	}

	// 抽奖路由

	lotteryGroup := r.Group("/api/lottery")

	{

		// 获取当前抽奖活动（可以允许未登录用户看，所以不用统一拦截，或者用带用户信息的中间件）

		lotteryGroup.GET("/current", middleware.AuthMiddleware(db, cfg.JWTSecret), lotteryHandler.GetCurrent)

		lotteryGroup.POST("/:id/join", middleware.AuthMiddleware(db, cfg.JWTSecret), lotteryHandler.Join)

	}

	lotteryAdminGroup := r.Group("/api/admin/lottery")

	lotteryAdminGroup.Use(middleware.AuthMiddleware(db, cfg.JWTSecret), middleware.SuperAdminMiddleware())

	{

		lotteryAdminGroup.POST("/:id/draw", lotteryHandler.Draw)

	}

	// 校园资讯公开只读路由
	campus := r.Group("/api/campus")
	{
		campus.GET("/articles/latest", campusArticleHandler.GetLatest)
		campus.GET("/articles", campusArticleHandler.List)
		campus.GET("/articles/:id", campusArticleHandler.GetDetail)
	}
	campusCalendars := r.Group("/api/campus-calendars")
	{
		campusCalendars.GET("/current", campusCalendarHandler.GetCurrent)
		campusCalendars.GET("/:academic_year", campusCalendarHandler.GetByAcademicYear)
	}

	calendarAdmin := r.Group("/api/admin/campus-calendars")
	calendarAdmin.Use(middleware.AuthMiddleware(db, cfg.JWTSecret), middleware.AdminMiddleware())
	{
		calendarAdmin.POST("/preview", campusCalendarHandler.Preview)
		calendarAdmin.POST("", campusCalendarHandler.CreateDraft)
		calendarAdmin.POST("/:id/publish", campusCalendarHandler.Publish)
		calendarAdmin.POST("/:id/archive", campusCalendarHandler.Archive)
	}
	classPeriodAdmin := r.Group("/api/admin/class-period-profiles")
	classPeriodAdmin.Use(middleware.AuthMiddleware(db, cfg.JWTSecret), middleware.AdminMiddleware())
	{
		classPeriodAdmin.POST("", classPeriodProfileHandler.Create)
		classPeriodAdmin.GET("", classPeriodProfileHandler.List)
		// 发布动作在 Handler 内再次校验 super_admin。
		classPeriodAdmin.POST("/:id/publish", classPeriodProfileHandler.Publish)
	}

	knowledgeAdmin := r.Group("/api/admin/ai/knowledge")
	knowledgeAdmin.Use(middleware.AuthMiddleware(db, cfg.JWTSecret), middleware.AdminMiddleware())
	{
		knowledgeAdmin.POST("/import", knowledgeHandler.Import)
		knowledgeAdmin.POST("/release", knowledgeHandler.ReleaseBatch)
		knowledgeAdmin.POST("/rollback", knowledgeHandler.RollbackBatch)
		knowledgeAdmin.GET("", knowledgeHandler.List)
		knowledgeAdmin.GET("/:id", knowledgeHandler.Read)
		knowledgeAdmin.POST("/:id/inspect", knowledgeHandler.Inspect)
		knowledgeAdmin.POST("/:id/reindex", knowledgeHandler.Reindex)
		// 高权限动作在 Handler 内再次校验 super_admin，不能只依赖路由组。
		knowledgeAdmin.POST("/:id/publish", knowledgeHandler.Publish)
		knowledgeAdmin.POST("/:id/revoke", knowledgeHandler.Revoke)
		knowledgeAdmin.POST("/:id/supersede", knowledgeHandler.Supersede)
	}

	// 能力探测保持可达，客户端据此读取统一的服务状态与账号配额。
	aiCapabilities := r.Group("/api/ai")
	aiCapabilities.Use(middleware.AuthMiddleware(db, cfg.JWTSecret))
	{
		aiCapabilities.GET("/capabilities", aiCapabilitiesHandler.Get)
		aiCapabilities.GET("/tools/competition-capability-profile", competitionHandler.GetAICompetitionCapabilityProfile)
		aiCapabilities.POST("/action-drafts/competition-plan", competitionHandler.CreateCompetitionPlanActionDraft)
	}
	if aiRuntimeHandler != nil {
		aiProtected := r.Group("/api/ai")
		aiProtected.Use(
			middleware.AuthMiddleware(db, cfg.JWTSecret),
			middleware.AIAccessMiddleware(cfg.AIEnabled),
		)
		{
			aiProtected.POST("/runs", aiRuntimeHandler.CreateRun)
			aiProtected.GET("/runs/:id", aiRuntimeHandler.GetRun)
			aiProtected.GET("/runs/:id/sources", aiRuntimeHandler.GetRunSources)
			aiProtected.GET("/runs/:id/events", aiRuntimeHandler.Events)
			aiProtected.GET("/sources/chunks/:chunk_id", aiRuntimeHandler.GetSourceChunk)
			aiProtected.POST("/runs/:id/consent", aiRuntimeHandler.SubmitRunConsent)
			aiProtected.POST("/runs/:id/cancel", aiRuntimeHandler.CancelRun)
			aiProtected.GET("/conversations", aiRuntimeHandler.ListConversations)
			aiProtected.POST("/conversations", aiRuntimeHandler.CreateConversation)
			aiProtected.GET("/conversations/:id", aiRuntimeHandler.GetConversation)
			aiProtected.DELETE("/conversations/:id", aiRuntimeHandler.DeleteConversation)
		}
	}

	// 版本信息。/api/version 是旧客户端兼容适配器，发布版本统一从
	// AppRelease 读取，避免与 /api/app/update 维护两套版本真相。
	r.GET("/api/version", func(c *gin.Context) {
		latest, err := appReleaseService.GetLatestPublished(c.Request.Context(), models.AppReleasePlatformAndroid, models.AppReleaseChannelStable)
		if err != nil && !errors.Is(err, gorm.ErrRecordNotFound) {
			c.JSON(http.StatusServiceUnavailable, gin.H{"code": "version_service_unavailable", "error": "版本服务暂不可用"})
			return
		}

		response := gin.H{
			"version":             "",
			"min_version":         "",
			"min_version_code":    int64(0),
			"force_update":        false,
			"download_url":        "",
			"github_download_url": "https://github.com/zhouwu97/SYLUlive/releases",
			"gitee_download_url":  "https://gitee.com/chunhezi/SYLUlive/releases",
			"update_msg":          "",
		}
		if latest == nil {
			c.JSON(http.StatusOK, response)
			return
		}

		currentVersionRaw := strings.TrimSpace(c.Query("version_code"))
		if currentVersionRaw == "" {
			currentVersionRaw = strings.TrimSpace(c.GetHeader("X-App-Version-Code"))
		}
		currentVersion, parseErr := strconv.ParseInt(currentVersionRaw, 10, 64)
		forceUpdate := parseErr == nil && currentVersion > 0 && currentVersion < latest.MinimumSupportedVersionCode
		downloadURL := "/api/app/releases/" + strconv.FormatUint(uint64(latest.ID), 10) + "/download"
		if latest.DeliveryMode == models.AppReleaseDeliveryModeExternalMarket {
			downloadURL = latest.ActionURL
		}
		response["version"] = latest.VersionName
		// 旧协议只有字符串字段，使用同源的最低支持构建号，同时提供
		// min_version_code 供能理解新协议的客户端使用。
		response["min_version"] = strconv.FormatInt(latest.MinimumSupportedVersionCode, 10)
		response["min_version_code"] = latest.MinimumSupportedVersionCode
		response["force_update"] = forceUpdate
		response["download_url"] = downloadURL
		response["update_msg"] = latest.Changelog
		c.JSON(http.StatusOK, response)
	})

	log.Println("服务器启动在 :8080")
	server := &http.Server{Addr: ":8080", Handler: r, ReadHeaderTimeout: 10 * time.Second}
	serveErr := serveUntilShutdown(appCtx, server, 10*time.Second)
	stopApp()
	examPaperStorageCron.Wait()
	eduCredentialCleanupCron.Wait()
	eduBindingRecoveryCron.Wait()
	feedMetricsCron.Wait()
	if serveErr != nil {
		log.Fatal("服务器运行失败:", serveErr)
	}

}

// ensureSystemSuperAdmin 确保系统只有指定超级管理员种子账号。

func ensureSystemSuperAdmin(db *gorm.DB, studentID, password string) {

	var existing models.User
	now := time.Now()

	if err := db.Where("student_id = ?", studentID).First(&existing).Error; err == nil {
		// 已存在的种子账号不因服务重启而覆盖密码或无条件轮换令牌；
		// 只有角色真的发生变化时才通过统一 Service 失效旧会话。
		if existing.Role != models.RoleSuperAdmin {
			if err := services.UpdateUserRoleAndInvalidateToken(db, existing.ID, models.RoleSuperAdmin); err != nil {
				log.Printf("系统超级管理员角色修复失败: %v", err)
			}
		}
		if err := db.Model(&existing).Updates(map[string]interface{}{
			"nickname":       "超级管理员",
			"credit_score":   100,
			"account_status": "active",
			"cancelled_at":   nil,
		}).Error; err != nil {
			log.Printf("系统超级管理员状态更新失败: %v", err)
		}
		// 超管种子账号不经教务注册流程，但必须满足登录查询的已认证身份条件。
		db.Model(&existing).
			Where("student_verified_at IS NULL").
			UpdateColumn("student_verified_at", now)

	} else {

		hashedPassword, _ := bcrypt.GenerateFromPassword([]byte(password), bcrypt.DefaultCost)

		user := models.User{

			StudentID: studentID,

			PasswordHash: string(hashedPassword),

			Nickname: "超级管理员",

			Role: models.RoleSuperAdmin,

			CreditScore: 100,

			AccountStatus: "active",

			StudentVerifiedAt: &now,
		}

		db.Create(&user)

	}

	var legacyAdmin models.User
	if err := db.Select("id", "role").Where("student_id = ? AND role = ?", "admin", models.RoleAdmin).First(&legacyAdmin).Error; err == nil {
		if err := services.UpdateUserRoleAndInvalidateToken(db, legacyAdmin.ID, models.RoleUser); err != nil {
			log.Printf("遗留 admin 账号降权失败: %v", err)
		}
	}

	log.Printf("系统超级管理员已就绪: %s", studentID)

}

// ensureSecurityHardeningSchema 建立文件访问范围和举报 pending 唯一约束，
// 并把已有公开业务引用的文件回填为 public；未被公开引用的历史文件保持 private。
func ensureSecurityHardeningSchema(db *gorm.DB) error {
	statements := []string{
		`ALTER TABLE files ADD COLUMN IF NOT EXISTS access_scope VARCHAR(16) NOT NULL DEFAULT 'private'`,
		`CREATE INDEX IF NOT EXISTS idx_files_access_scope ON files (access_scope)`,
		`UPDATE files SET access_scope = 'private' WHERE access_scope IS NULL OR access_scope = ''`,
		`UPDATE files
SET status = 'active', claimed_at = COALESCE(claimed_at, CURRENT_TIMESTAMP)
WHERE EXISTS (SELECT 1 FROM messages WHERE messages.file_id = files.id)`,
		`UPDATE files SET access_scope = 'public'
WHERE EXISTS (SELECT 1 FROM post_images WHERE post_images.file_id = files.id)
   OR EXISTS (SELECT 1 FROM reply_images WHERE reply_images.file_id = files.id)
   OR EXISTS (SELECT 1 FROM users WHERE users.avatar = files.path OR users.avatar LIKE files.path || '?%')
   OR EXISTS (SELECT 1 FROM users WHERE users.background = files.path OR users.background LIKE files.path || '?%')
   OR EXISTS (SELECT 1 FROM water_sections
              WHERE water_sections.avatar_url = files.path
                 OR water_sections.cover_url = files.path
                 OR water_sections.cover_portrait_url = files.path
                 OR water_sections.cover_landscape_url = files.path
                 OR water_sections.cover_square_url = files.path)`,
		`UPDATE files SET access_scope = 'public'
WHERE EXISTS (SELECT 1 FROM canteens
              WHERE canteens.verified = TRUE
                AND (canteens.image = files.path
                  OR canteens.image LIKE files.path || '?%'))
   OR EXISTS (SELECT 1
              FROM canteen_ratings
              JOIN canteens ON canteens.id = canteen_ratings.canteen_id
              WHERE canteens.verified = TRUE
                AND (canteen_ratings.images LIKE '%' || files.path || '%'
                  OR canteen_ratings.images LIKE '%/' || files.path || '%'))`,
		`DROP INDEX IF EXISTS uq_pending_report_target`,
		`CREATE UNIQUE INDEX IF NOT EXISTS uq_pending_report_target
 ON reports (reporter_id, target_type, target_id)
 WHERE status = 'pending'`,
	}
	for _, statement := range statements {
		if err := db.Exec(statement).Error; err != nil {
			return err
		}
	}
	return nil
}

// ensureCanteenNormalizedNameIndex 回填历史数据后建立数据库级唯一约束。
func ensureCanteenNormalizedNameIndex(db *gorm.DB) error {
	var canteens []models.Canteen
	if err := db.Select("id", "name", "normalized_name").Find(&canteens).Error; err != nil {
		return err
	}
	seen := make(map[string]uint, len(canteens))
	for _, canteen := range canteens {
		normalized := strings.ToLower(strings.Join(strings.Fields(strings.TrimSpace(canteen.Name)), " "))
		if previousID, exists := seen[normalized]; exists {
			return errors.New("食堂名称规范化后重复: id=" + strconv.FormatUint(uint64(previousID), 10) + ", id=" + strconv.FormatUint(uint64(canteen.ID), 10))
		}
		seen[normalized] = canteen.ID
		if canteen.NormalizedName != normalized {
			if err := db.Model(&models.Canteen{}).Where("id = ?", canteen.ID).Update("normalized_name", normalized).Error; err != nil {
				return err
			}
		}
	}
	return db.Exec("CREATE UNIQUE INDEX IF NOT EXISTS idx_canteens_normalized_name ON canteens (normalized_name)").Error
}

func ensureFeatureCollaborationIndexes(db *gorm.DB) error {
	statements := []string{
		`CREATE UNIQUE INDEX IF NOT EXISTS uq_featured_application_pending_post
ON featured_applications(post_id)
WHERE status = 'pending'`,
		`CREATE UNIQUE INDEX IF NOT EXISTS uq_collaboration_pending_user_post
ON collaboration_applications(post_id, applicant_id)
WHERE status = 'pending'`,
	}
	for _, statement := range statements {
		if err := db.Exec(statement).Error; err != nil {
			return err
		}
	}
	return nil
}

func ensurePostPinColumns(db *gorm.DB) error {
	statements := []string{
		`ALTER TABLE posts ADD COLUMN IF NOT EXISTS is_pinned BOOLEAN NOT NULL DEFAULT FALSE`,
		`ALTER TABLE posts ADD COLUMN IF NOT EXISTS pinned_at TIMESTAMPTZ`,
		`ALTER TABLE posts ADD COLUMN IF NOT EXISTS pinned_until TIMESTAMPTZ`,
		`ALTER TABLE posts ADD COLUMN IF NOT EXISTS pinned_by BIGINT NOT NULL DEFAULT 0`,
		`ALTER TABLE posts ADD COLUMN IF NOT EXISTS pinned_weight INTEGER NOT NULL DEFAULT 0`,
		`ALTER TABLE posts ADD COLUMN IF NOT EXISTS pinned_reason VARCHAR(500) NOT NULL DEFAULT ''`,
		`CREATE INDEX IF NOT EXISTS idx_posts_active_pin ON posts (board_id, is_pinned, pinned_until, pinned_weight, pinned_at)`,
	}
	for _, statement := range statements {
		if err := db.Exec(statement).Error; err != nil {
			return err
		}
	}
	return nil
}

func ensurePostMarketTagsColumn(db *gorm.DB) error {
	return db.Exec(`ALTER TABLE posts ADD COLUMN IF NOT EXISTS market_tags VARCHAR(200) NOT NULL DEFAULT ''`).Error
}

// ensureAppReleaseIndexes 建立版本检查与超管列表所需的索引和数据约束。
// 版本号在同一平台和渠道下不可复用；PostgreSQL 约束以 NOT VALID 方式新增，
// 避免历史脏数据阻塞上线，同时仍会约束之后的任何新写入。
func ensureAppReleaseIndexes(db *gorm.DB) error {
	statements := []string{
		`CREATE UNIQUE INDEX IF NOT EXISTS uq_app_release_platform_channel_version
		 ON app_releases (platform, channel, version_code)
		 WHERE status IN ('draft','published','withdrawn')`,
		`CREATE INDEX IF NOT EXISTS idx_app_release_lookup
		 ON app_releases (platform, channel, status, version_code DESC)`,
		`CREATE INDEX IF NOT EXISTS idx_app_release_published_at
		 ON app_releases (published_at)`,
	}
	for _, statement := range statements {
		if err := db.Exec(statement).Error; err != nil {
			return err
		}
	}
	if db.Dialector.Name() == "postgres" {
		constraints := []string{
			`DO $$ BEGIN
				IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'chk_app_release_version_code_positive') THEN
					ALTER TABLE app_releases ADD CONSTRAINT chk_app_release_version_code_positive CHECK (version_code > 0) NOT VALID;
				END IF;
			END $$`,
			`DO $$ BEGIN
				IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'chk_app_release_minimum_supported') THEN
					ALTER TABLE app_releases ADD CONSTRAINT chk_app_release_minimum_supported CHECK (minimum_supported_version_code > 0 AND minimum_supported_version_code <= version_code) NOT VALID;
				END IF;
			END $$`,
			`DO $$ BEGIN
				IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'chk_app_release_status') THEN
					ALTER TABLE app_releases ADD CONSTRAINT chk_app_release_status CHECK (status IN ('draft', 'published', 'withdrawn')) NOT VALID;
				END IF;
			END $$`,
		}
		for _, statement := range constraints {
			if err := db.Exec(statement).Error; err != nil {
				return err
			}
		}
	}
	return nil
}

// ensurePostActivitySchema 回填历史讨论时间并建立首页候选查询索引。
// Post 字段由 AutoMigrate 创建；这里的 SQL 同时兼容 PostgreSQL 与 SQLite。
func ensurePostActivitySchema(db *gorm.DB) error {
	statements := []string{
		`UPDATE posts
SET last_activity_at = COALESCE(
    (SELECT MAX(replies.created_at) FROM replies WHERE replies.post_id = posts.id AND replies.status = 'normal'),
    posts.created_at
)
WHERE last_activity_at IS NULL OR last_activity_at < posts.created_at`,
		`CREATE INDEX IF NOT EXISTS idx_posts_home_created ON posts(board_id, status, created_at DESC)`,
		`CREATE INDEX IF NOT EXISTS idx_posts_home_activity ON posts(board_id, status, last_activity_at DESC)`,
		`CREATE INDEX IF NOT EXISTS idx_posts_home_featured ON posts(board_id, is_featured, created_at DESC)`,
	}
	for _, statement := range statements {
		if err := db.Exec(statement).Error; err != nil {
			return err
		}
	}
	return nil
}
