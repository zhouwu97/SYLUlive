package main

import (
	"log"
	"net/http"
	"os"
	"strings"

	"github.com/gin-gonic/gin"
	"github.com/glebarez/sqlite"
	"golang.org/x/crypto/bcrypt"
	"gorm.io/driver/postgres"
	"gorm.io/gorm"
	"shenliyuan/internal/config"
	"shenliyuan/internal/handlers"
	"shenliyuan/internal/middleware"
	"shenliyuan/internal/models"
)

func main() {
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

	// 自动迁移
	if err := db.AutoMigrate(
		&models.User{},
		&models.Post{},
		&models.PostImage{},
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
	); err != nil {
		log.Fatal("数据库迁移失败:", err)
	}

	// 创建唯一系统超级管理员；普通管理员后续通过邀请流程产生。
	ensureSystemSuperAdmin(db)

	r := gin.Default()

	// CORS中间件
	r.Use(func(c *gin.Context) {
		c.Header("Access-Control-Allow-Origin", "*")
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
	replyHandler := handlers.NewReplyHandler(db)
	likeHandler := handlers.NewLikeHandler(db)
	messageHandler := handlers.NewMessageHandler(db)
	announcementHandler := handlers.NewAnnouncementHandler(db)
	reportHandler := handlers.NewReportHandler(db)
	appealHandler := handlers.NewAppealHandler(db)
	invitationHandler := handlers.NewInvitationHandler(db, cfg.JWTSecret)
	uploadHandler := handlers.NewUploadHandler(cfg.UploadDir, cfg.MaxFileSize, db)
	superAdminHandler := handlers.NewSuperAdminHandler(db)
	eduHandler := handlers.NewEduHandler(db)
	examHandler := handlers.NewExamHandler()
	tutorialHandler := handlers.NewTutorialHandler(db)
	teacherHandler := handlers.NewTeacherHandler(db)
	majorHandler := handlers.NewMajorHandler(db)

	// 初始化教务服务配置
	handlers.EduServiceConfig.BaseURL = cfg.EduServiceURL
	handlers.VerifyCodeConfig.SMTPHost = cfg.SMTPHost
	handlers.VerifyCodeConfig.SMTPPort = cfg.SMTPPort
	handlers.VerifyCodeConfig.SMTPUser = cfg.SMTPUser
	handlers.VerifyCodeConfig.SMTPPass = cfg.SMTPPass
	handlers.VerifyCodeConfig.SMTPFrom = cfg.SMTPFrom
	handlers.SetMajorLogDB(db)

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
		auth.POST("/change_password", middleware.AuthMiddleware(cfg.JWTSecret), authHandler.ChangePassword)
	}

	// 用户路由
	user := r.Group("/api/user")
	user.Use(middleware.AuthMiddleware(cfg.JWTSecret))
	{
		user.GET("/profile", userHandler.GetProfile)
		user.PUT("/profile", userHandler.UpdateProfile)
		user.PUT("/avatar", userHandler.UpdateAvatar)
		user.PUT("/background", userHandler.UpdateBackground)
		user.PUT("/nightmode", userHandler.UpdateNightMode)
		user.GET("/invitations", invitationHandler.GetPending)
		user.POST("/invitations/:id/accept", invitationHandler.Accept)
		user.POST("/invitations/:id/reject", invitationHandler.Reject)
		user.GET("/:id", userHandler.GetUserInfo)
	}

	// 帖子路由
	posts := r.Group("/api/posts")
	{
		posts.GET("", postHandler.GetList)
		posts.GET("/:id", postHandler.GetOne)
		posts.GET("/:id/replies", replyHandler.GetList)
	}
	posts.Use(middleware.AuthMiddleware(cfg.JWTSecret))
	{
		posts.POST("", postHandler.Create)
		posts.PUT("/:id", postHandler.Update)
		posts.DELETE("/:id", postHandler.Delete)
		posts.POST("/:id/replies", replyHandler.Create)
		posts.POST("/:id/appeal", appealHandler.Create)
	}

	// 回复路由（带认证）
	replies := r.Group("/api/replies")
	replies.Use(middleware.AuthMiddleware(cfg.JWTSecret))
	{
		replies.DELETE("/:id", replyHandler.Delete)
		replies.GET("/me", replyHandler.GetMeList)
	}

	// 点赞路由
	like := r.Group("/api")
	like.Use(middleware.AuthMiddleware(cfg.JWTSecret))
	{
		like.POST("/posts/:id/like", likeHandler.LikePost)
		like.DELETE("/posts/:id/like", likeHandler.UnlikePost)
		like.POST("/replies/:id/like", likeHandler.LikeReply)
		like.DELETE("/replies/:id/like", likeHandler.UnlikeReply)
	}

	// 私信路由
	messages := r.Group("/api/messages")
	messages.Use(middleware.AuthMiddleware(cfg.JWTSecret))
	{
		messages.GET("/conversations", messageHandler.GetConversations)
		messages.GET("/conversations/:id", messageHandler.GetMessages)
		messages.POST("/:user_id", messageHandler.Send)
		messages.DELETE("/conversations/:id", messageHandler.DeleteConversation)
	}

	// 公告路由
	announcements := r.Group("/api/announcements")
	{
		announcements.GET("", announcementHandler.GetList)
		announcements.GET("/active", announcementHandler.GetActive)
	}
	announcementsAuth := announcements.Group("")
	announcementsAuth.Use(middleware.AuthMiddleware(cfg.JWTSecret))
	{
		announcementsAuth.GET("/unread", announcementHandler.GetUnread)
		announcementsAuth.GET("/:id", announcementHandler.GetOne)
		announcementsAuth.POST("/:id/read", announcementHandler.MarkRead)
	}
	announcementsAdmin := announcements.Group("")
	announcementsAdmin.Use(middleware.AuthMiddleware(cfg.JWTSecret), middleware.AdminMiddleware())
	{
		announcementsAdmin.POST("", announcementHandler.Create)
		announcementsAdmin.PUT("/:id", announcementHandler.Update)
		announcementsAdmin.DELETE("/:id", announcementHandler.Delete)
	}

	// 举报路由
	reports := r.Group("/api/reports")
	reports.Use(middleware.AuthMiddleware(cfg.JWTSecret))
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
	appeals.Use(middleware.AuthMiddleware(cfg.JWTSecret))
	{
		appeals.GET("", appealHandler.GetList)
		appeals.GET("/:id", appealHandler.GetOne)
		appeals.POST("/:id/vote", appealHandler.Vote)
	}

	// 管理员邀请路由
	admin := r.Group("/api/admin")
	admin.Use(middleware.AuthMiddleware(cfg.JWTSecret), middleware.AdminMiddleware())
	{
		admin.GET("/candidates", invitationHandler.GetCandidates)
		admin.GET("/members", invitationHandler.GetMembers)
		admin.POST("/invite/:user_id", invitationHandler.Create)
		admin.GET("/invitations/pending", invitationHandler.GetApprovalList)
		admin.POST("/invitations/:id/vote", invitationHandler.VoteApprove)
		admin.GET("/removals/pending", teacherHandler.GetRemovalRequests)
	}
	adminSuper := r.Group("/api/admin")
	adminSuper.Use(middleware.AuthMiddleware(cfg.JWTSecret), middleware.SuperAdminMiddleware())
	{
		adminSuper.POST("/promote", invitationHandler.DirectPromote)
	}

	// 上传路由
	r.POST("/api/upload", middleware.AuthMiddleware(cfg.JWTSecret), uploadHandler.Upload)
	r.POST("/api/upload_multiple", middleware.AuthMiddleware(cfg.JWTSecret), uploadHandler.UploadMultiple)

	// 教务系统路由
	edu := r.Group("/api/edu")
	{
		edu.GET("/status", middleware.AuthMiddleware(cfg.JWTSecret), eduHandler.GetEduStatus)
		edu.POST("/bind", middleware.AuthMiddleware(cfg.JWTSecret), eduHandler.BindEdu)
		edu.DELETE("/bind", middleware.AuthMiddleware(cfg.JWTSecret), eduHandler.UnbindEdu)
		edu.POST("/courses", middleware.AuthMiddleware(cfg.JWTSecret), eduHandler.GetCourses)
		edu.POST("/grades", middleware.AuthMiddleware(cfg.JWTSecret), eduHandler.GetGrades)
		edu.POST("/pre_verify", eduHandler.PreVerify) // 注册前验证教务账号
	}

	// 超级管理员路由
	superAdmin := r.Group("/api/super")
	superAdmin.Use(middleware.AuthMiddleware(cfg.JWTSecret), middleware.SuperAdminMiddleware())
	{
		superAdmin.GET("/users", superAdminHandler.GetUsers)
		superAdmin.PUT("/users/:id/role", superAdminHandler.UpdateUserRole)
		superAdmin.PUT("/users/:id/credit", superAdminHandler.UpdateUserCredit)
		superAdmin.POST("/users/:id/reset_password", superAdminHandler.ResetUserPassword)
		superAdmin.DELETE("/users/:id", superAdminHandler.DeleteUser)
		superAdmin.GET("/stats", superAdminHandler.GetStatistics)
		superAdmin.GET("/admin_logs", superAdminHandler.GetAdminLogs)
		superAdmin.GET("/invitations/pending", invitationHandler.GetApprovalList)
		superAdmin.POST("/invitations/:id/approve", invitationHandler.Approve)
	}

	// 题库提取路由
	r.POST("/api/exam/extract", middleware.AuthMiddleware(cfg.JWTSecret), examHandler.Extract)

	// 教程页面路由（公开读，管理员写）
	r.GET("/api/tutorial/:key", tutorialHandler.Get)
	r.PUT("/api/tutorial/:key", middleware.AuthMiddleware(cfg.JWTSecret), middleware.AdminMiddleware(), tutorialHandler.Update)

	// 避雷版块 - 教师路由
	teacher := r.Group("/api/teachers")
	{
		teacher.GET("", teacherHandler.GetList)
	}
	teacherAdmin := teacher.Group("")
	teacherAdmin.Use(middleware.AuthMiddleware(cfg.JWTSecret), middleware.AdminMiddleware())
	{
		teacherAdmin.GET("/pending", teacherHandler.GetPending)
		teacherAdmin.GET("/logs", teacherHandler.GetLogs)
		teacherAdmin.PUT("/:id/verify", teacherHandler.Verify)
		teacherAdmin.DELETE("/:id/reject", teacherHandler.RejectTeacher)
	}
	teacherAuth := teacher.Group("")
	teacherAuth.Use(middleware.AuthMiddleware(cfg.JWTSecret))
	{
		teacherAuth.GET("/:id", teacherHandler.GetDetail)
		teacherAuth.POST("", teacherHandler.Create)
		teacherAuth.POST("/:id/rate", teacherHandler.Rate)
		teacherAuth.DELETE("/rating/:id", teacherHandler.DeleteRating)
		teacherAuth.POST("/rating/:id/report", teacherHandler.ReportRating)
	}
	teacherAdminVotes := teacher.Group("")
	teacherAdminVotes.Use(middleware.AuthMiddleware(cfg.JWTSecret), middleware.AdminMiddleware())
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
	majorAdmin.Use(middleware.AuthMiddleware(cfg.JWTSecret), middleware.AdminMiddleware())
	{
		majorAdmin.GET("/pending", majorHandler.GetPending)
		majorAdmin.PUT("/:id/verify", majorHandler.Verify)
		majorAdmin.DELETE("/:id/reject", majorHandler.Reject)
	}
	majorAuth := major.Group("")
	majorAuth.Use(middleware.AuthMiddleware(cfg.JWTSecret))
	{
		majorAuth.GET("/:id", majorHandler.GetDetail)
		majorAuth.POST("", majorHandler.Create)
		majorAuth.POST("/:id/rate", majorHandler.Rate)
	}

	// 违规管理
	violation := r.Group("/api/violations")
	violation.Use(middleware.AuthMiddleware(cfg.JWTSecret))
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

	// 版本信息
	r.GET("/api/version", func(c *gin.Context) {
		c.JSON(http.StatusOK, gin.H{
			"version":             "1.1.1",
			"force_update":        false,
			"download_url":        "https://github.com/zhouwu97/SYLUlive/releases",
			"github_download_url": "https://github.com/zhouwu97/SYLUlive/releases",
			"gitee_download_url":  "https://gitee.com/chunhezi/SYLUlive/releases",
			"update_msg":          "新版本可用，建议选择网络较快的下载源。",
		})
	})

	log.Println("服务器启动在 :8080")
	if err := r.Run(":8080"); err != nil {
		log.Fatal("服务器启动失败:", err)
	}
}

// ensureSystemSuperAdmin 确保系统只有指定超级管理员种子账号。
func ensureSystemSuperAdmin(db *gorm.DB) {
	const studentID = "20052403060128"
	const password = "zhoukangwu"

	var existing models.User
	if err := db.Where("student_id = ?", studentID).First(&existing).Error; err == nil {
		hashedPassword, _ := bcrypt.GenerateFromPassword([]byte(password), bcrypt.DefaultCost)
		db.Model(&existing).Updates(map[string]interface{}{
			"password_hash": string(hashedPassword),
			"nickname":      "超级管理员",
			"role":          models.RoleSuperAdmin,
			"credit_score":  100,
		})
	} else {
		hashedPassword, _ := bcrypt.GenerateFromPassword([]byte(password), bcrypt.DefaultCost)
		user := models.User{
			StudentID:    studentID,
			PasswordHash: string(hashedPassword),
			Nickname:     "超级管理员",
			Role:         models.RoleSuperAdmin,
			CreditScore:  100,
		}
		db.Create(&user)
	}

	db.Model(&models.User{}).
		Where("role = ? AND student_id <> ?", models.RoleSuperAdmin, studentID).
		Update("role", models.RoleUser)

	db.Model(&models.User{}).
		Where("student_id = ? AND role = ?", "admin", models.RoleAdmin).
		Update("role", models.RoleUser)

	log.Printf("系统超级管理员已就绪: %s", studentID)
}
