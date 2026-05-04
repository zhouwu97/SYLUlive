package main

import (
	"log"
	"net/http"
	"os"
	"strings"

	"github.com/glebarez/sqlite"
	"github.com/gin-gonic/gin"
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
	db.AutoMigrate(
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
	)

	// 创建种子数据
	createDefaultUsers(db, cfg.SuperAdminDefaultPwd)
	ensureAdminUser(db, "20052403060128", "zhoukangwu")

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
	invitationHandler := handlers.NewInvitationHandler(db)
	uploadHandler := handlers.NewUploadHandler(cfg.UploadDir, cfg.MaxFileSize, db)
	superAdminHandler := handlers.NewSuperAdminHandler(db)
	eduHandler := handlers.NewEduHandler(db)
	examHandler := handlers.NewExamHandler()
	tutorialHandler := handlers.NewTutorialHandler(db)
	teacherHandler := handlers.NewTeacherHandler(db)
	majorHandler := handlers.NewMajorHandler(db)

	// 初始化教务服务配置
	handlers.EduServiceConfig.BaseURL = cfg.EduServiceURL
	handlers.SetMajorLogDB(db)

	// 静态文件服务
	r.Static("/uploads", cfg.UploadDir)

	// 认证路由
	auth := r.Group("/api")
	{
		auth.POST("/login", authHandler.Login)
		auth.POST("/login_edu", authHandler.LoginEdu)
		auth.POST("/register_with_edu", authHandler.RegisterWithEdu)
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
		announcements.GET("/:id", announcementHandler.GetOne)
	}
	announcementsAuth := announcements.Group("")
	announcementsAuth.Use(middleware.AuthMiddleware(cfg.JWTSecret))
	{
		announcementsAuth.GET("/unread", announcementHandler.GetUnread)
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
	admin.Use(middleware.AuthMiddleware(cfg.JWTSecret))
	{
		admin.GET("/candidates", invitationHandler.GetCandidates)
		admin.POST("/invite/:user_id", invitationHandler.Create)
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
	teacherAuth := teacher.Group("")
	teacherAuth.Use(middleware.AuthMiddleware(cfg.JWTSecret))
	{
		teacherAuth.GET("/:id", teacherHandler.GetDetail)
		teacherAuth.POST("", teacherHandler.Create)
		teacherAuth.POST("/:id/rate", teacherHandler.Rate)
		teacherAuth.DELETE("/rating/:id", teacherHandler.DeleteRating)
		teacherAuth.POST("/rating/:id/report", teacherHandler.ReportRating)
		teacherAuth.POST("/admin/:id/vote-remove", teacherHandler.VoteRemoveAdmin)
		teacherAuth.GET("/admin/:id/votes", teacherHandler.GetAdminVotes)
	}
	teacherAdmin := teacher.Group("")
	teacherAdmin.Use(middleware.AuthMiddleware(cfg.JWTSecret), middleware.AdminMiddleware())
	{
		teacherAdmin.PUT("/:id/verify", teacherHandler.Verify)
		teacherAdmin.DELETE("/:id/reject", teacherHandler.RejectTeacher)
		teacherAdmin.GET("/pending", teacherHandler.GetPending)
		teacherAdmin.GET("/logs", teacherHandler.GetLogs)
	}

	// 专业榜路由
	major := r.Group("/api/majors")
	{
		major.GET("", majorHandler.GetList)
	}
	majorAuth := major.Group("")
	majorAuth.Use(middleware.AuthMiddleware(cfg.JWTSecret))
	{
		majorAuth.GET("/:id", majorHandler.GetDetail)
		majorAuth.POST("", majorHandler.Create)
		majorAuth.POST("/:id/rate", majorHandler.Rate)
	}
	majorAdmin := major.Group("")
	majorAdmin.Use(middleware.AuthMiddleware(cfg.JWTSecret), middleware.AdminMiddleware())
	{
		majorAdmin.PUT("/:id/verify", majorHandler.Verify)
		majorAdmin.DELETE("/:id/reject", majorHandler.Reject)
		majorAdmin.GET("/pending", majorHandler.GetPending)
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
			"version":       "1.0.0",
			"force_update":  false,
			"download_url":  "https://github.com/zhouwu97/SYLUlive/releases",
			"update_msg":    "新版本可用",
		})
	})

	log.Println("服务器启动在 :8080")
	r.Run(":8080")
}

// createDefaultUsers 创建默认用户（超级管理员和普通管理员）
func createDefaultUsers(db *gorm.DB, superAdminPwd string) {
	var count int64
	db.Model(&models.User{}).Count(&count)
	if count > 0 {
		return
	}

	// 创建超级管理员
	hashedPassword, _ := bcrypt.GenerateFromPassword([]byte(superAdminPwd), bcrypt.DefaultCost)
	superAdmin := models.User{
		StudentID:    "super_admin",
		PasswordHash: string(hashedPassword),
		Nickname:     "超级管理员",
		Role:         models.RoleSuperAdmin,
		CreditScore:  100,
	}
	db.Create(&superAdmin)

	// 创建普通管理员
	adminPassword, _ := bcrypt.GenerateFromPassword([]byte("admin123"), bcrypt.DefaultCost)
	admin := models.User{
		StudentID:    "admin",
		PasswordHash: string(adminPassword),
		Nickname:     "管理员",
		Role:         models.RoleAdmin,
		CreditScore:  100,
	}
	db.Create(&admin)

	// 创建测试用户
	testPassword, _ := bcrypt.GenerateFromPassword([]byte("test123456"), bcrypt.DefaultCost)
	testUser := models.User{
		StudentID:    "2024001",
		PasswordHash: string(testPassword),
		Nickname:     "测试用户",
		Role:         models.RoleUser,
		CreditScore:  100,
	}
	db.Create(&testUser)

	log.Println("默认用户创建成功: super_admin/super123456, admin/admin123, 2024001/test123456")
}

// ensureAdminUser 确保指定管理员账号存在
func ensureAdminUser(db *gorm.DB, studentID string, password string) {
	var existing models.User
	if err := db.Where("student_id = ?", studentID).First(&existing).Error; err == nil {
		return // 已存在
	}
	hashedPassword, _ := bcrypt.GenerateFromPassword([]byte(password), bcrypt.DefaultCost)
	user := models.User{
		StudentID:    studentID,
		PasswordHash: string(hashedPassword),
		Nickname:     "超级管理员",
		Role:         models.RoleSuperAdmin,
		CreditScore:  100,
	}
	db.Create(&user)
	log.Printf("管理员账号已创建: %s", studentID)
}
