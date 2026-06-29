package main

import (
	"context"
	"errors"
	"log"
	"net/http"
	"os"
	"strings"
	"time"
	_ "time/tzdata"

	"github.com/gin-gonic/gin"

	"gorm.io/driver/sqlite"

	"golang.org/x/crypto/bcrypt"

	"gorm.io/driver/postgres"

	"gorm.io/gorm"

	"shenliyuan/internal/clients"

	"shenliyuan/internal/config"

	"shenliyuan/internal/handlers"

	"shenliyuan/internal/middleware"

	"shenliyuan/internal/models"

	"shenliyuan/internal/services"

	"shenliyuan/internal/tasks"
)

func main() {
	// 强制设置时区为东八区（北京时间），使用 FixedZone 确保在任何没有 tzdata 的系统上也能生效
	time.Local = time.FixedZone("CST", 8*3600)

	cfg := config.Load()

	// 确保上传目录存在

	os.MkdirAll(cfg.UploadDir, 0755)

	var db *gorm.DB

	var err error

	if strings.Contains(cfg.DSN, "host=") || strings.Contains(cfg.DSN, "port=") {

		db, err = gorm.Open(postgres.Open(cfg.DSN), &gorm.Config{})

		log.Println("使用 PostgreSQL 数据库")

	} else {

		db, err = gorm.Open(sqlite.Open(cfg.DSN), &gorm.Config{})

		log.Println("使用 SQLite 数据库")

	}

	if err != nil {
		log.Fatal("数据库连接失败:", err)
	}

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

	if err := db.AutoMigrate(

		&models.User{},

		&models.Post{},

		&models.PostImage{},
		&models.FeaturedApplication{},
		&models.CollaborationApplication{},
		&models.PostRevisionProposal{},
		&models.ReputationLog{},

		&models.Reply{},

		&models.ReplyImage{},

		&models.Like{},

		&models.File{},

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

		&models.UserViolation{},

		&models.AdminLog{},

		&models.AnnouncementRead{},

		&models.Major{},

		&models.MajorRating{},

		&models.AdminVote{},

		&models.AdminRemovalVote{},

		&models.Notification{},

		&models.CheckIn{},

		&models.ExpLog{},

		&models.LotteryEvent{},

		&models.LotteryParticipant{},
		&models.CachedQuestion{},
		&models.AiUsageLog{},
		&models.SystemConfig{},
		&models.Canteen{},
		&models.CanteenRating{},
		&models.UserFollow{},
		// 融智云考助手独立业务表
		&models.YunkaoAiProvider{},
		&models.YunkaoAiModel{},
		&models.YunkaoWallet{},
		&models.YunkaoRechargeOrder{},
		&models.YunkaoUsageLog{},
		&models.YunkaoQuestionCache{},
		&models.YunkaoWrongReport{},
		&models.YunkaoPayOrder{},
		&models.OneClassPayOrder{},
		&models.OneClassUpdate{},
		// 校园资讯
		&models.CampusArticle{},
		&models.JWCSyncState{},
		&models.CompetitionCategory{},
		&models.CompetitionEvent{},
		&models.CompetitionEventAttachment{},
		&models.UserCompetitionCalendar{},
		&models.UserCompetitionCalendarItem{},
		&models.CalendarShareSnapshot{},
		&models.CalendarShareSnapshotItem{},
		&models.CompetitionImportBatch{},
	); err != nil {

		log.Fatal("数据库迁移失败:", err)

	}

	if err := models.EnsureConversationIndexes(db); err != nil {
		log.Fatal("私信索引迁移失败:", err)
	}
	if err := models.EnsureCompetitionCategories(db); err != nil {
		log.Fatal("竞赛分类种子初始化失败:", err)
	}
	if err := ensureFeatureCollaborationIndexes(db); err != nil {
		log.Fatal("精华共同创作索引迁移失败:", err)
	}

	// 回填旧公告的缺失字段默认值（公告模型新增 Status/DisplayMode/Priority）
	db.Exec(`UPDATE announcements SET status = 'published' WHERE status = ''`)
	db.Exec(`UPDATE announcements SET display_mode = 'center' WHERE display_mode = ''`)
	db.Exec(`UPDATE announcements SET priority = 'normal' WHERE priority = ''`)

	// 启动时自动修复可能不同步的评论数和点赞数
	log.Println("正在同步数据(评论数、帖子点赞、用户总获赞)...")
	db.Exec(`UPDATE posts SET reply_count = (SELECT COUNT(*) FROM replies WHERE replies.post_id = posts.id AND replies.status = 'normal')`)
	db.Exec(`UPDATE posts SET like_count = (SELECT COUNT(*) FROM likes WHERE likes.target_id = posts.id AND likes.target_type = 'post')`)
	db.Exec(`UPDATE users SET total_likes_received = (SELECT COUNT(*) FROM likes WHERE target_type = 'post' AND target_id IN (SELECT id FROM posts WHERE author_id = users.id))`)
	log.Println("同步完成")

	// 确保默认超级管理员

	ensureSystemSuperAdmin(db, cfg.SuperAdminID, cfg.SuperAdminPass)

	// 确保雨课堂 JS 注入脚本存在
	ensureInjectScript(db)

	r := gin.Default()

	// CORS中间件

	r.Use(func(c *gin.Context) {

		origin := c.GetHeader("Origin")
		if origin != "" {
			c.Header("Access-Control-Allow-Origin", origin)
			c.Header("Access-Control-Allow-Credentials", "true")
		} else {
			c.Header("Access-Control-Allow-Origin", "*")
		}

		c.Header("Access-Control-Allow-Methods", "GET, POST, PUT, DELETE, OPTIONS")

		c.Header("Access-Control-Allow-Headers", "Content-Type, Authorization")

		if c.Request.Method == "OPTIONS" {

			c.AbortWithStatus(204)

			return

		}

		c.Next()

	})

	// 初始化处理器

	authHandler := handlers.NewAuthHandler(db, cfg.JWTSecret)

	userHandler := handlers.NewUserHandler(db)

	postHandler := handlers.NewPostHandler(db)
	searchHandler := handlers.NewSearchHandler(db, postHandler)
	competitionHandler := handlers.NewCompetitionHandler(db)

	replyHandler := handlers.NewReplyHandler(db, cfg.JPushAppKey, cfg.JPushMasterSecret)

	likeHandler := handlers.NewLikeHandler(db)

	messageHandler := handlers.NewMessageHandler(db, services.NewNotificationService(cfg.JPushAppKey, cfg.JPushMasterSecret))

	announcementHandler := handlers.NewAnnouncementHandler(db)

	reportHandler := handlers.NewReportHandler(db)

	appealHandler := handlers.NewAppealHandler(db)

	invitationHandler := handlers.NewInvitationHandler(db, cfg.JWTSecret)

	uploadHandler := handlers.NewUploadHandler(cfg.UploadDir, cfg.MaxFileSize, db)

	superAdminHandler := handlers.NewSuperAdminHandler(db)

	eduHandler := handlers.NewEduHandler(db)

	examHandler := handlers.NewExamHandler()

	tutorialHandler := handlers.NewTutorialHandler(db)
	aiSolveHandler := handlers.NewAiSolveHandler(db, cfg.DeepSeekAPIKey, cfg.DeepSeekBaseURL)
	configHandler := handlers.NewConfigHandler(db)

	teacherHandler := handlers.NewTeacherHandler(db)

	majorHandler := handlers.NewMajorHandler(db)

	canteenHandler := handlers.NewCanteenHandler(db)

	feedbackHandler := handlers.NewFeedbackHandler(db)

	checkinHandler := handlers.NewCheckInHandler(db)

	notificationHandler := handlers.NewNotificationHandler(db)

	erkeHandler := handlers.NewErkeHandler(db)

	lotteryHandler := handlers.NewLotteryHandler(db)

	vipHandler := handlers.NewVipHandler(db, cfg.JPushAppKey, cfg.JPushMasterSecret)

	// 融智云考助手独立业务处理器
	yunkaoSolveHandler := handlers.NewYunkaoSolveHandler(db)
	yunkaoWalletHandler := handlers.NewYunkaoWalletHandler(db)
	yunkaoAdminHandler := handlers.NewYunkaoAdminHandler(db)
	yunkaoPayHandler := handlers.NewYunkaoPayHandler(db)
	oneClassPayHandler := handlers.NewOneClassPayHandler(db)

	// 初始化融智云考助手默认提供商和模型
	yunkaoAdminHandler.SeedDefaultProviders()

	// 初始化教务服务配置

	handlers.EduServiceConfig.BaseURL = cfg.EduServiceURL

	handlers.VerifyCodeConfig.SMTPHost = cfg.SMTPHost

	handlers.VerifyCodeConfig.SMTPPort = cfg.SMTPPort

	handlers.VerifyCodeConfig.SMTPUser = cfg.SMTPUser

	handlers.VerifyCodeConfig.SMTPPass = cfg.SMTPPass

	handlers.VerifyCodeConfig.SMTPFrom = cfg.SMTPFrom

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

		go tasks.StartCampusSyncTask(context.Background(), campusSyncServices, cfg)
		log.Println("校园资讯同步已启用 (JWC + Competition)")
	} else {
		log.Println("校园资讯同步未启用 (JWC_SYNC_ENABLED=false)")
	}

	campusArticleHandler := handlers.NewCampusArticleHandler(db, campusSyncServices...)

	// 启动后台定时任务

	tasks.StartLotteryCron(db)

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

		c.JSON(http.StatusOK, gin.H{
			"status": "ok",
		})
	})

	// 静态文件服务

	r.Static("/uploads", cfg.UploadDir)

	// 认证路由

	auth := r.Group("/api")

	{

		auth.POST("/send_code", authHandler.SendVerifyCode)

		auth.POST("/verify_code", authHandler.VerifyCode)

		auth.POST("/register", authHandler.Register)

		auth.POST("/login", authHandler.Login)

		auth.POST("/login_edu", authHandler.LoginEdu)

		auth.POST("/register_with_edu", authHandler.RegisterWithEdu)

		auth.POST("/forgot_password", authHandler.ForgotPassword)

		auth.POST("/change_password", middleware.AuthMiddleware(db, cfg.JWTSecret), authHandler.ChangePassword)

	}

	// 公共配置路由，无需 JWT 鉴权
	publicGroup := r.Group("/api/v1/config")
	{
		publicGroup.GET("/inject-script", configHandler.GetInjectScript)
	}

	// AI 答题路由
	ai := r.Group("/api/v1/question")
	ai.Use(middleware.AuthMiddleware(db, cfg.JWTSecret))
	{
		ai.POST("/solve", aiSolveHandler.Solve)
		ai.POST("/mark_wrong", aiSolveHandler.MarkWrong)
		ai.POST("/confirm_cache", aiSolveHandler.ConfirmCache)
	}

	// ============ 融智云考助手独立业务路由 ============

	// 普通用户路由
	yunkao := r.Group("/api/yunkao")
	yunkao.Use(middleware.AuthMiddleware(db, cfg.JWTSecret))
	{
		yunkao.GET("/models", yunkaoSolveHandler.GetModels)
		yunkao.GET("/wallet", yunkaoWalletHandler.GetWallet)
		yunkao.GET("/wallet/logs", yunkaoWalletHandler.GetWalletLogs)
		yunkao.POST("/solve", yunkaoSolveHandler.Solve)
		yunkao.POST("/report-wrong", yunkaoSolveHandler.ReportWrong)
		yunkao.POST("/rewrite", yunkaoSolveHandler.Rewrite)
	}

	// 管理员路由 (admin 和 super_admin)
	yunkaoAdmin := r.Group("/api/yunkao/admin")
	yunkaoAdmin.Use(middleware.AuthMiddleware(db, cfg.JWTSecret), middleware.AdminMiddleware())
	{
		// 提供商管理
		yunkaoAdmin.GET("/providers", yunkaoAdminHandler.GetProviders)
		yunkaoAdmin.POST("/providers", yunkaoAdminHandler.CreateProvider)
		yunkaoAdmin.PUT("/providers/:id", yunkaoAdminHandler.UpdateProvider)
		yunkaoAdmin.DELETE("/providers/:id", yunkaoAdminHandler.DeleteProvider)
		yunkaoAdmin.GET("/providers/:id/remote-models", yunkaoAdminHandler.FetchProviderModels)

		// 模型管理
		yunkaoAdmin.GET("/models", yunkaoAdminHandler.GetModels)
		yunkaoAdmin.POST("/models", yunkaoAdminHandler.CreateModel)
		yunkaoAdmin.PUT("/models/:id", yunkaoAdminHandler.UpdateModel)
		yunkaoAdmin.DELETE("/models/:id", yunkaoAdminHandler.DeleteModel)

		// 用户钱包管理
		yunkaoAdmin.GET("/wallets", yunkaoAdminHandler.GetUserWallets)
		yunkaoAdmin.POST("/wallet/recharge", yunkaoAdminHandler.RechargeWallet)
		yunkaoAdmin.POST("/wallet/deduct", yunkaoAdminHandler.DeductWallet)

		// 错题审核
		yunkaoAdmin.GET("/reports", yunkaoAdminHandler.GetWrongReports)
		yunkaoAdmin.POST("/reports/:id/review", yunkaoAdminHandler.ReviewWrongReport)

		// 使用日志
		yunkaoAdmin.GET("/usage-logs", yunkaoAdminHandler.GetUsageLogs)

		// 统计概览
		yunkaoAdmin.GET("/stats", yunkaoAdminHandler.GetAdminStats)
	}

	// 支付路由（不需要 auth 的回调接口）
	r.Any("/api/yunkao/pay/notify", yunkaoPayHandler.PayNotify)
	r.Any("/api/yunkao/pay/vmq_notify", yunkaoPayHandler.VmqNotify)
	r.GET("/api/yunkao/pay/recharge-page", yunkaoPayHandler.RechargePage)
	r.GET("/api/yunkao/pay/checkout", yunkaoPayHandler.CheckoutPage)
	r.GET("/api/yunkao/pay/status", yunkaoPayHandler.PayStatus)
	r.GET("/api/yunkao/pay/start", yunkaoPayHandler.StartPayment)
	r.GET("/api/yunkao/pay/qrcode", yunkaoPayHandler.PaymentQRCode)

	// OneClass 公开购买路由（仅易支付）
	r.Any("/api/oneclass/pay/notify", oneClassPayHandler.PayNotify)
	r.GET("/api/oneclass/pay/buy", oneClassPayHandler.BuyPage)
	r.POST("/api/oneclass/pay/create", middleware.AuthMiddleware(db, cfg.JWTSecret), oneClassPayHandler.CreateOrder)
	r.POST("/api/oneclass/pay/sync", middleware.AuthMiddleware(db, cfg.JWTSecret), oneClassPayHandler.SyncLicense)
	r.GET("/api/oneclass/pay/checkout", oneClassPayHandler.CheckoutPage)
	r.GET("/api/oneclass/pay/status", oneClassPayHandler.PayStatus)
	r.GET("/api/oneclass/pay/start", oneClassPayHandler.StartPayment)
	r.GET("/api/oneclass/pay/qrcode", oneClassPayHandler.PaymentQRCode)
	r.GET("/api/oneclass/client/version", oneClassPayHandler.ClientVersion)

	oneClassAdmin := r.Group("/api/oneclass/admin")
	oneClassAdmin.Use(middleware.AuthMiddleware(db, cfg.JWTSecret), middleware.AdminMiddleware())
	{
		oneClassAdmin.GET("/orders", oneClassPayHandler.AdminGetOrders)
		oneClassAdmin.GET("/updates", oneClassPayHandler.AdminListUpdates)
		oneClassAdmin.POST("/updates", oneClassPayHandler.AdminCreateUpdate)
		oneClassAdmin.PUT("/updates/:id", oneClassPayHandler.AdminUpdateUpdate)
	}

	// 支付路由（需要 auth）
	yunkaoPay := r.Group("/api/yunkao/pay")
	yunkaoPay.Use(middleware.AuthMiddleware(db, cfg.JWTSecret))
	{
		yunkaoPay.POST("/create", yunkaoPayHandler.CreatePayOrder)
		yunkaoPay.GET("/orders", yunkaoPayHandler.GetPayOrders)
	}

	// 管理员支付管理
	yunkaoAdminPay := r.Group("/api/yunkao/admin/pay")
	yunkaoAdminPay.Use(middleware.AuthMiddleware(db, cfg.JWTSecret), middleware.AdminMiddleware())
	{
		yunkaoAdminPay.GET("/orders", yunkaoPayHandler.AdminGetPayOrders)
		yunkaoAdminPay.GET("/config", yunkaoPayHandler.GetPayConfig)
		yunkaoAdminPay.PUT("/config", yunkaoPayHandler.UpdatePayConfig)
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

		user.PUT("/device_token", userHandler.UpdateDeviceToken)

		user.GET("/invitations", invitationHandler.GetPending)

		user.POST("/invitations/:id/accept", invitationHandler.Accept)

		user.POST("/invitations/:id/reject", invitationHandler.Reject)

		user.GET("/replies/received", replyHandler.GetReceivedList)

		user.GET("/notifications/unread_count", notificationHandler.GetUnreadCount)

		user.POST("/notifications/read", notificationHandler.MarkAllRead)

		user.GET("/competition-calendar", competitionHandler.GetCalendar)
		user.POST("/competition-calendar/init", competitionHandler.InitCalendar)
		user.PUT("/competition-calendar", competitionHandler.UpdateCalendar)
		user.DELETE("/competition-calendar", competitionHandler.DeleteCalendar)
		user.POST("/competition-calendar/items", competitionHandler.CreateCalendarItem)
		user.POST("/competition-calendar/items/copy-from-official/:event_id", competitionHandler.CopyOfficialToCalendar)
		user.PUT("/competition-calendar/items/:id", competitionHandler.UpdateCalendarItem)
		user.DELETE("/competition-calendar/items/:id", competitionHandler.DeleteCalendarItem)
		user.POST("/competition-calendar/items/:id/pin", competitionHandler.PinCalendarItem)
		user.POST("/competition-calendar/items/reorder", competitionHandler.ReorderCalendarItems)
		user.POST("/competition-calendar/share", competitionHandler.ShareCalendar)
		user.POST("/competition-calendar/share/:share_code/revoke", competitionHandler.RevokeShare)
		user.POST("/competition-calendar/import-share/preview", competitionHandler.PreviewShareImport)
		user.POST("/competition-calendar/import-share/commit", competitionHandler.CommitShareImport)
		user.GET("/featured-applications", postHandler.GetMyFeaturedApplications)
		user.GET("/collaboration-applications/sent", postHandler.GetMyCollaborationApplicationsSent)
		user.GET("/collaboration-applications/received", postHandler.GetMyCollaborationApplicationsReceived)
		user.GET("/revision-proposals/sent", postHandler.GetMyRevisionProposalsSent)
		user.GET("/revision-proposals/received", postHandler.GetMyRevisionProposalsReceived)

		user.POST("/checkin", checkinHandler.DoCheckIn)

		user.GET("/checkin/status", checkinHandler.GetStatus)

		user.POST("/:id/follow", userHandler.Follow)
		user.DELETE("/:id/follow", userHandler.Unfollow)
		user.GET("/:id/is-following", userHandler.IsFollowing)
	}

	userOptional := r.Group("/api/user")
	userOptional.Use(middleware.OptionalAuthMiddleware(db, cfg.JWTSecret))
	{
		userOptional.GET("/:id", userHandler.GetUserInfo)
		userOptional.GET("/:id/following", userHandler.GetFollowing)
		userOptional.GET("/:id/followers", userHandler.GetFollowers)
		userOptional.GET("/:id/posts/count", userHandler.GetUserPostCount)
		userOptional.GET("/:id/posts", userHandler.GetUserPosts)
	}

	// 帖子路由

	posts := r.Group("/api/posts")

	posts.Use(middleware.OptionalAuthMiddleware(db, cfg.JWTSecret))

	{

		posts.GET("", postHandler.GetList)

		posts.GET("/featured", postHandler.GetFeaturedList)

		posts.GET("/:id", postHandler.GetOne)

		posts.GET("/:id/replies", replyHandler.GetList)

	}

	r.GET("/api/search", middleware.OptionalAuthMiddleware(db, cfg.JWTSecret), searchHandler.Search)

	r.POST("/api/collaboration-applications/:id/approve", middleware.AuthMiddleware(db, cfg.JWTSecret), postHandler.ApproveCollaborationApplication)
	r.POST("/api/collaboration-applications/:id/reject", middleware.AuthMiddleware(db, cfg.JWTSecret), postHandler.RejectCollaborationApplication)
	r.POST("/api/revision-proposals/:id/approve", middleware.AuthMiddleware(db, cfg.JWTSecret), postHandler.ApproveRevisionProposal)
	r.POST("/api/revision-proposals/:id/reject", middleware.AuthMiddleware(db, cfg.JWTSecret), postHandler.RejectRevisionProposal)

	competitions := r.Group("/api/competitions")
	{
		competitions.GET("/categories", competitionHandler.GetCategories)
		competitions.GET("/events", competitionHandler.ListEvents)
		competitions.GET("/events/:id", competitionHandler.GetEvent)
	}

	postsAuth := r.Group("/api/posts")

	postsAuth.Use(middleware.AuthMiddleware(db, cfg.JWTSecret))

	{

		postsAuth.POST("", postHandler.Create)

		postsAuth.PUT("/:id", postHandler.Update)

		postsAuth.DELETE("/:id", postHandler.Delete)

		postsAuth.POST("/:id/featured-applications", postHandler.CreateFeaturedApplication)
		postsAuth.POST("/:id/collaboration-applications", postHandler.CreateCollaborationApplication)
		postsAuth.POST("/:id/revision-proposals", postHandler.CreateRevisionProposal)

		postsAuth.POST("/:id/replies", replyHandler.Create)

		postsAuth.POST("/:id/appeal", appealHandler.Create)

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

	// 私信路由

	messages := r.Group("/api/messages")

	messages.Use(middleware.AuthMiddleware(db, cfg.JWTSecret))

	{

		messages.GET("/conversations", messageHandler.GetConversations)

		messages.GET("/conversations/:id", messageHandler.GetMessages)

		messages.POST("/:user_id", messageHandler.Send)

		messages.POST("/conversations/:id/read", messageHandler.MarkRead)

		messages.GET("/unread_count", messageHandler.GetUnreadCount)

	}

	// 公告路由

	announcements := r.Group("/api/announcements")

	{

		announcements.GET("", announcementHandler.GetList)

		announcements.GET("/active", announcementHandler.GetActive)

	}

	announcementsAuth := announcements.Group("")

	announcementsAuth.Use(middleware.AuthMiddleware(db, cfg.JWTSecret))

	{
		// 静态路由必须在 /:id 之前注册
		announcementsAuth.GET("/unread", announcementHandler.GetUnread)
		announcementsAuth.GET("/unread-count", announcementHandler.GetUnreadCount)
		announcementsAuth.POST("/read-all", announcementHandler.MarkAllRead)

		announcementsAuth.GET("/:id", announcementHandler.GetOne)
		announcementsAuth.POST("/:id/read", announcementHandler.MarkRead)

	}

	announcementsAdmin := announcements.Group("")

	announcementsAdmin.Use(middleware.AuthMiddleware(db, cfg.JWTSecret), middleware.AdminMiddleware())

	{
		announcementsAdmin.GET("/admin/list", announcementHandler.GetAdminList)

		announcementsAdmin.POST("", announcementHandler.Create)

		announcementsAdmin.PUT("/:id", announcementHandler.Update)

		announcementsAdmin.DELETE("/:id", announcementHandler.Delete)

	}

	// 公告别名路由：App 直连公网 IP 时，部分网络会卡住包含
	// "announcement" 的明文 HTTP 路径；保留旧路径兼容，客户端走 notices。
	notices := r.Group("/api/notices")

	{

		notices.GET("", announcementHandler.GetList)

		notices.GET("/active", announcementHandler.GetActive)

	}

	noticesAuth := notices.Group("")

	noticesAuth.Use(middleware.AuthMiddleware(db, cfg.JWTSecret))

	{
		// 静态路由必须在 /:id 之前注册
		noticesAuth.GET("/unread", announcementHandler.GetUnread)
		noticesAuth.GET("/unread-count", announcementHandler.GetUnreadCount)
		noticesAuth.POST("/read-all", announcementHandler.MarkAllRead)

		noticesAuth.GET("/:id", announcementHandler.GetOne)
		noticesAuth.POST("/:id/read", announcementHandler.MarkRead)

	}

	noticesAdmin := notices.Group("")

	noticesAdmin.Use(middleware.AuthMiddleware(db, cfg.JWTSecret), middleware.AdminMiddleware())

	{
		noticesAdmin.GET("/admin/list", announcementHandler.GetAdminList)

		noticesAdmin.POST("", announcementHandler.Create)

		noticesAdmin.PUT("/:id", announcementHandler.Update)

		noticesAdmin.DELETE("/:id", announcementHandler.Delete)

	}

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

		appeals.GET("", appealHandler.GetList)

		appeals.GET("/:id", appealHandler.GetOne)

		appeals.POST("/:id/vote", appealHandler.Vote)

	}

	// 管理员邀请路由

	admin := r.Group("/api/admin")

	admin.Use(middleware.AuthMiddleware(db, cfg.JWTSecret), middleware.AdminMiddleware())

	{

		admin.GET("/candidates", invitationHandler.GetCandidates)

		admin.GET("/members", invitationHandler.GetMembers)

		admin.POST("/invite/:user_id", invitationHandler.Create)

		admin.GET("/invitations/pending", invitationHandler.GetApprovalList)

		admin.POST("/invitations/:id/vote", invitationHandler.VoteApprove)

		admin.GET("/removals/pending", teacherHandler.GetRemovalRequests)

		admin.GET("/featured-applications", postHandler.AdminGetFeaturedApplications)
		admin.POST("/featured-applications/:id/approve", postHandler.AdminApproveFeaturedApplication)
		admin.POST("/featured-applications/:id/reject", postHandler.AdminRejectFeaturedApplication)
		admin.POST("/posts/:id/unfeature", postHandler.AdminUnfeaturePost)
		admin.POST("/competitions/categories", competitionHandler.AdminCreateCategory)
		admin.PUT("/competitions/categories/:id", competitionHandler.AdminUpdateCategory)
		admin.DELETE("/competitions/categories/:id", competitionHandler.AdminDeleteCategory)
		admin.GET("/competitions/events", competitionHandler.AdminListEvents)
		admin.POST("/competitions/events", competitionHandler.AdminCreateEvent)
		admin.PUT("/competitions/events/:id", competitionHandler.AdminUpdateEvent)
		admin.DELETE("/competitions/events/:id", competitionHandler.AdminDeleteEvent)
		admin.POST("/competitions/events/:id/archive", competitionHandler.AdminArchiveEvent)
		admin.POST("/competitions/events/:id/publish", competitionHandler.AdminPublishEvent)
		admin.POST("/competitions/events/:id/verify", competitionHandler.AdminVerifyEvent)
		admin.POST("/competitions/import-json/preview", competitionHandler.AdminImportJSONPreview)
		admin.POST("/competitions/import-json/commit", competitionHandler.AdminImportJSONCommit)
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

		edu.POST("/courses", middleware.AuthMiddleware(db, cfg.JWTSecret), eduHandler.GetCourses)

		edu.POST("/grades", middleware.AuthMiddleware(db, cfg.JWTSecret), eduHandler.GetGrades)

		edu.POST("/grades/detail", middleware.AuthMiddleware(db, cfg.JWTSecret), eduHandler.GetGradeDetail)

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
		superAdmin.POST("/users/:id/ai_balance/recharge", superAdminHandler.RechargeAiBalance)

		superAdmin.POST("/users/:id/reset_password", superAdminHandler.ResetUserPassword)

		superAdmin.DELETE("/users/:id", superAdminHandler.DeleteUser)

		superAdmin.GET("/stats", superAdminHandler.GetStatistics)

		superAdmin.GET("/admin_logs", superAdminHandler.GetAdminLogs)

		superAdmin.POST("/admin_logs/revoke_exp", superAdminHandler.RevokeAdminExp)

		superAdmin.GET("/ai_config", superAdminHandler.GetAiConfig)

		superAdmin.PUT("/ai_config", superAdminHandler.UpdateAiConfig)

		superAdmin.GET("/invitations/pending", invitationHandler.GetApprovalList)

		superAdmin.POST("/invitations/:id/approve", invitationHandler.Approve)

		// VIP 管理路由（超级管理员）
		superAdmin.POST("/vip/grant", vipHandler.GrantVip)
		superAdmin.DELETE("/vip/:user_id", vipHandler.RevokeVip)
		superAdmin.POST("/vip/push_update", vipHandler.PushUpdateToVip)

	}

	// VIP 状态查询路由（普通用户，需登录）
	r.GET("/api/vip/status", middleware.AuthMiddleware(db, cfg.JWTSecret), vipHandler.CheckVip)

	// 题库提取路由

	r.POST("/api/exam/extract", middleware.AuthMiddleware(db, cfg.JWTSecret), examHandler.Extract)

	// 二课查询路由

	r.POST("/api/erke/scores", middleware.AuthMiddleware(db, cfg.JWTSecret), erkeHandler.GetScores)

	// 用户反馈路由

	r.POST("/api/feedback", middleware.OptionalAuthMiddleware(db, cfg.JWTSecret), feedbackHandler.Submit)

	// 教程页面路由（公开读，管理员写）

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

	}

	// 食堂榜路由

	canteen := r.Group("/api/canteens")

	{

		canteen.GET("", canteenHandler.GetList)

	}

	canteenAdmin := canteen.Group("")

	canteenAdmin.Use(middleware.AuthMiddleware(db, cfg.JWTSecret), middleware.AdminMiddleware())

	{

		canteenAdmin.DELETE("/:id", canteenHandler.DeleteCanteen)
		
		canteenAdmin.PUT("/:id/image", canteenHandler.UpdateImage)

	}

	canteenAuth := canteen.Group("")

	canteenAuth.Use(middleware.AuthMiddleware(db, cfg.JWTSecret))

	{

		canteenAuth.GET("/:id", canteenHandler.GetDetail)

		canteenAuth.POST("", canteenHandler.Create)

		canteenAuth.POST("/:id/rate", canteenHandler.Rate)

	}

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

	// 版本信息

	r.GET("/api/version", func(c *gin.Context) {

		c.JSON(http.StatusOK, gin.H{

			"version": "1.5.19",

			"min_version": "1.4.0", // 增加最低版本限制，低于此版本的客户端将被强制更新

			"force_update": false, // 保留兼容旧版逻辑

			"download_url": "http://156.233.229.232:8080/uploads/app-release.apk",

			"github_download_url": "https://github.com/zhouwu97/SYLUlive/releases",

			"gitee_download_url": "https://gitee.com/chunhezi/SYLUlive/releases",

			"update_msg": "1. 修复推送通知点击后无法精准跳转二级回复及应用崩溃问题\n2. 完善帖子详情和结构化路由机制\n3. 修复相关组件报错",
		})

	})

	log.Println("服务器启动在 :8080")

	if err := r.Run(":8080"); err != nil {

		log.Fatal("服务器启动失败:", err)

	}

}

// ensureSystemSuperAdmin 确保系统只有指定超级管理员种子账号。

func ensureSystemSuperAdmin(db *gorm.DB, studentID, password string) {

	var existing models.User

	if err := db.Where("student_id = ?", studentID).First(&existing).Error; err == nil {

		hashedPassword, _ := bcrypt.GenerateFromPassword([]byte(password), bcrypt.DefaultCost)

		db.Model(&existing).Updates(map[string]interface{}{

			"password_hash": string(hashedPassword),

			"nickname": "超级管理员",

			"role": models.RoleSuperAdmin,

			"credit_score": 100,
		})

	} else {

		hashedPassword, _ := bcrypt.GenerateFromPassword([]byte(password), bcrypt.DefaultCost)

		user := models.User{

			StudentID: studentID,

			PasswordHash: string(hashedPassword),

			Nickname: "超级管理员",

			Role: models.RoleSuperAdmin,

			CreditScore: 100,
		}

		db.Create(&user)

	}

	// 已移除硬编码提升超级管理员代码

	// 移除将其他超级管理员降级的代码，允许多个超级管理员共存

	// db.Model(&models.User{}).

	// 	Where("role = ? AND student_id <> ?", models.RoleSuperAdmin, studentID).

	// 	Update("role", models.RoleUser)

	db.Model(&models.User{}).
		Where("student_id = ? AND role = ?", "admin", models.RoleAdmin).
		Update("role", models.RoleUser)

	log.Printf("系统超级管理员已就绪: %s", studentID)

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

// 注意：每次重启服务均会重置该配置，如需永久修改请直接更改此处硬编码
// ensureInjectScript 确保数据库里有一份基础的拦截脚本
func ensureInjectScript(db *gorm.DB) {
	jsCode := `(function() {
    if (window.__aiExamData !== undefined) return;
    window.__aiExamData = null;
    window.__aiSnapshotBackedUp = false;

    window.AiHelper = {
        parseRange: function(str) {
            let indices = new Set();
            let parts = str.split(/[,，\s]+/);
            parts.forEach(part => {
                if (!part) return;
                if (part.includes('-') || part.includes('~')) {
                    let bounds = part.split(/[-~]/);
                    let start = parseInt(bounds[0], 10);
                    let end = parseInt(bounds[1], 10);
                    if (!isNaN(start) && !isNaN(end)) {
                        for(let i = Math.min(start, end); i <= Math.max(start, end); i++) indices.add(i);
                    }
                } else {
                    let num = parseInt(part, 10);
                    if (!isNaN(num)) indices.add(num);
                }
            });
            return Array.from(indices).sort((a,b)=>a-b);
        },
        
        _extractProblems: function() {
            if (!window.__aiExamData) return [];
            let rawObj = JSON.parse(window.__aiExamData);
            let problems = [];
            let recurse = (o, depth) => {
                if (depth > 20 || !o) return;
                
                if (Array.isArray(o)) {
                    // 兼容旧版：经典课后作业的连续题目数组
                    if (o.length > 0 && typeof o[0] === 'object' && o[0] !== null && (o[0].options !== undefined || o[0].problem_id !== undefined || o[0].content !== undefined)) {
                        // 避免误判 options 内部的数组
                        if (o[0].key !== undefined && o[0].value !== undefined) {
                            o.forEach(v => recurse(v, depth+1));
                        } else {
                            problems.push(...o);
                            return; 
                        }
                    } else {
                        o.forEach(v => recurse(v, depth+1));
                    }
                } else if (typeof o === 'object') {
                    // 兼容新版直播课：深埋在幻灯片里的 problem 对象
                    if ('problem' in o && typeof o.problem === 'object' && o.problem !== null && ('problemId' in o.problem || 'problem_id' in o.problem || 'body' in o.problem)) {
                        problems.push(o.problem);
                        return; 
                    }
                    // 游离的单题对象
                    if ('problem_id' in o || 'problemId' in o) {
                        problems.push(o);
                        return;
                    }
                    if (('body' in o && 'id' in o) || ('content' in o && 'id' in o) || ('title' in o && 'id' in o)) {
                        if ('options' in o || 'ProblemType' in o || 'problemType' in o || 'type' in o || 'user_answer' in o || 'answer' in o || 'score' in o) {
                            problems.push(o);
                            return;
                        }
                    }
                    for (let k in o) recurse(o[k], depth+1);
                }
            };
            recurse(rawObj, 0);
            
            // 去重
            let uniqueProblems = [];
            let seen = new Set();
            problems.forEach(p => {
                let id = p.problem_id || p.problemId || JSON.stringify(p);
                if (!seen.has(id)) {
                    seen.add(id);
                    uniqueProblems.push(p);
                }
            });
            return uniqueProblems;
        },
        
        getTotalQuestions: function() {
            return this._extractProblems().length;
        },
        
        sliceExamData: function(rangeStr) {
            let problems = this._extractProblems();
            if (problems.length === 0) return null;
            
            let indices = this.parseRange(rangeStr);
            let sliced = [];
            
            for (let i = 0; i < problems.length; i++) {
                let globalIndex = i + 1;
                if (indices.length === 0 || indices.includes(globalIndex)) {
                    let copy = Object.assign({}, problems[i]);
                    copy.__originalIndex = globalIndex;
                    sliced.push(copy);
                }
            }
            return JSON.stringify(sliced);
        },
        
        doAutoAnswer: function(answerStr, mode) {
            let isLiveClass = window.location.pathname.includes('/lesson/fullscreen/');
            if (isLiveClass && window.__activeLiveProblem) {
                let problem = window.__activeLiveProblem;
                let result = [];
                let matches = answerStr.match(/[A-F]/g);
                if (matches) {
                    result = Array.from(new Set(matches));
                } else {
                    result = [answerStr];
                }
                
                let pType = 1;
                if (window.__aiExamData) {
                    let typeMatch = window.__aiExamData.match(new RegExp('"problem_id":"?' + problem.prob + '"?.*?"problemType":(\\\\d+)'));
                    if (typeMatch) pType = parseInt(typeMatch[1]);
                }
                
                fetch('/api/v3/lesson/problem/answer', {
                    method: 'POST',
                    headers: {
                        'Content-Type': 'application/json',
                        'Authorization': 'Bearer ' + localStorage.getItem('Authorization'),
                        'xtbz': 'ykt',
                        'X-Client': 'h5'
                    },
                    body: JSON.stringify({
                        problemId: problem.prob,
                        problemType: pType,
                        dt: Date.now(),
                        result: result
                    })
                }).then(res => res.json()).then(data => {
                    if (data.code === 0) {
                        alert('✅ 混合双擎: API极速提交成功！(免疫前端变化)');
                    } else if (data.code === 4) {
                        fetch('/api/v3/lesson/problem/retry', {
                            method: 'POST',
                            headers: {
                                'Content-Type': 'application/json',
                                'Authorization': 'Bearer ' + localStorage.getItem('Authorization'),
                                'xtbz': 'ykt',
                                'X-Client': 'h5'
                            },
                            body: JSON.stringify({
                                problems: [{
                                    problemId: problem.prob,
                                    problemType: pType,
                                    dt: problem.dt + 2000,
                                    result: result
                                }]
                            })
                        }).then(r=>r.json()).then(d => {
                            if (d.code === 0) alert('🚀 混合双擎: 超时补救提交成功！(利用协议漏洞)');
                            else alert('❌ 提交失败: ' + d.msg);
                        });
                    } else {
                        alert('❌ 提交失败: ' + data.msg);
                    }
                });
                
                // 直播课专属的视觉反馈渲染（因为直播课 DOM 按钮通常只有 A B C D 字母）
                if (matches) {
                    let optionLabels = document.querySelectorAll('.option-item, .el-radio, .el-checkbox, .live-option-btn, span, div'); 
                    optionLabels.forEach(label => {
                        let text = label.innerText.trim().toUpperCase();
                        // 如果按钮文本恰好是单个字母，且在答案字母中
                        if (text.length === 1 && /^[A-F]$/.test(text) && result.includes(text)) {
                            label.click();
                            label.style.border = "4px solid #4CAF50";
                            label.style.backgroundColor = "rgba(76, 175, 80, 0.2)";
                        }
                    });
                }
                
                let submitBtn = document.querySelector('.submit-btn, .btn-submit, .live-submit-btn');
                if(submitBtn) setTimeout(() => submitBtn.click(), 1500);
                
                return; // 直播课处理完毕，直接返回
            }

            if (mode === 'full') {
                 // 课后作业的物理 DOM 渲染（通过选项文字模糊匹配，无视乱序）
                 let lines = answerStr.split('\\n');
                 let optionLabels = document.querySelectorAll('.option-item, .el-radio, .el-checkbox, .live-option-btn'); 
                 
                 lines.forEach(line => {
                     // 1. 尝试匹配完整的选项文字
                     let cleanAnswer = line.replace(/^(?:\\d+|[A-Z])[\\.\\:、\\s]+/, '').trim();
                     let letterMatch = line.match(/^(?:\\d+[\\.\\:、\\s]*)?([A-F])/);
                     let letter = letterMatch ? letterMatch[1] : null;
                     
                     if (!cleanAnswer && !letter) return;
                     
                     optionLabels.forEach(label => {
                         let labelText = label.innerText.trim();
                         let cleanLabel = labelText.replace(/^(?:\\d+|[A-Z])[\\.\\:、\\s]+/, '').trim();
                         let labelLetterMatch = labelText.match(/^[0-9]*[\\.\\:、\\s]*([A-F])/);
                         let labelLetter = labelLetterMatch ? labelLetterMatch[1] : null;
                         
                         let matched = false;
                         if (cleanAnswer && cleanLabel && (cleanLabel.includes(cleanAnswer) || cleanAnswer.includes(cleanLabel))) {
                             matched = true;
                         } else if (letter && letter === labelLetter) {
                             matched = true;
                         } else if (letter && labelText === letter) {
                             matched = true;
                         }
                         
                         if(matched) {
                             label.click(); 
                             label.style.border = "2px solid #4CAF50";
                         }
                     });
                 });
                 
                 let submitBtn = document.querySelector('.submit-btn, .btn-submit, .live-submit-btn');
                 if(submitBtn) setTimeout(() => submitBtn.click(), 1500);
            }
        }
    };

    window.__activeLiveProblem = null;
    const originalWebSocket = window.WebSocket;
    class MyWebSocket extends originalWebSocket {
        constructor(url, protocols) {
            super(url, protocols);
            this.addEventListener('message', (evt) => {
                try {
                    let msg = JSON.parse(evt.data);
                    if (msg.op === 'unlockproblem') {
                        window.__activeLiveProblem = msg.problem;
                        if (window.flutter_inappwebview && window.flutter_inappwebview.callHandler) {
                            window.flutter_inappwebview.callHandler('YuketangLiveProblem', msg.problem.prob);
                        }
                    }
                } catch(e) {}
            });
        }
    }
    window.WebSocket = MyWebSocket;

    function handleIntercept(jsonStr) {
        window.__aiExamData = jsonStr;
        if (window.flutter_inappwebview && window.flutter_inappwebview.callHandler) {
            window.flutter_inappwebview.callHandler('YuketangIntercepted', '');
            if (!window.__aiSnapshotBackedUp) {
                window.flutter_inappwebview.callHandler('YuketangBackup', jsonStr);
                window.__aiSnapshotBackedUp = true;
            }
        }
    }

    const originalFetch = window.fetch;
    window.fetch = async function(...args) {
        const url = typeof args[0] === 'string' ? args[0] : args[0].url;
        const response = await originalFetch.apply(this, args);
        const clone = response.clone(); 
        clone.json().then(data => {
            let jsonStr = JSON.stringify(data);
            let isProb = jsonStr.includes('"options"') || jsonStr.includes('"problem_id"') || jsonStr.includes('"problemId"') || jsonStr.includes('"ProblemType"') || jsonStr.includes('"problemType"');
            let isGenericProb = (jsonStr.includes('"body"') || jsonStr.includes('"content"')) && url && (url.includes('exam') || url.includes('exercise') || url.includes('test') || url.includes('homework') || url.includes('problem'));
            if (isProb || isGenericProb) handleIntercept(jsonStr);
        }).catch(e => {});
        return response;
    };

    const originalXHR = window.XMLHttpRequest;
    function newXHR() {
        const xhr = new originalXHR();
        const originalOpen = xhr.open;
        xhr.open = function(method, url, ...args) {
            this._url = url;
            return originalOpen.apply(this, [method, url, ...args]);
        };
        xhr.addEventListener('load', function() {
            try {
                let jsonStr = '';
                if (xhr.responseType === 'json') {
                    jsonStr = JSON.stringify(xhr.response);
                } else {
                    jsonStr = xhr.responseText;
                }
                if (!jsonStr) return;
                let isProb = jsonStr.includes('"options"') || jsonStr.includes('"problem_id"') || jsonStr.includes('"problemId"') || jsonStr.includes('"ProblemType"') || jsonStr.includes('"problemType"');
                let isGenericProb = (jsonStr.includes('"body"') || jsonStr.includes('"content"')) && xhr._url && (xhr._url.includes('exam') || xhr._url.includes('exercise') || xhr._url.includes('test') || xhr._url.includes('homework') || xhr._url.includes('problem'));
                if (isProb || isGenericProb) handleIntercept(jsonStr);
            } catch(e) {
                console.error('XHR intercept error:', e);
            }
        });
        return xhr;
    }
    window.XMLHttpRequest = newXHR;
})();`

	var config models.SystemConfig
	if err := db.Where("config_key = ?", "yuketang_inject_js").First(&config).Error; err != nil {
		db.Create(&models.SystemConfig{
			ConfigKey:   "yuketang_inject_js",
			ConfigValue: jsCode,
			Description: "雨课堂默认题目拦截脚本",
		})
	} else {
		// 总是更新代码以防本地修改
		config.ConfigValue = jsCode
		db.Save(&config)
	}
}
