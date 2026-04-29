package main

import (
	"log"
	"os"

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

	db, err := gorm.Open(postgres.Open(cfg.DSN), &gorm.Config{})
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
	)

	// 创建种子数据
	createDefaultUsers(db, cfg.SuperAdminDefaultPwd)

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

	// 静态文件服务
	r.Static("/uploads", cfg.UploadDir)

	// 认证路由
	auth := r.Group("/api")
	{
		auth.POST("/register", authHandler.Register)
		auth.POST("/login", authHandler.Login)
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
		announcements.GET("/:id", announcementHandler.GetOne)
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
	edu.Use(middleware.AuthMiddleware(cfg.JWTSecret))
	{
		edu.POST("/bind", eduHandler.BindEdu)
		edu.DELETE("/bind", eduHandler.UnbindEdu)
		edu.GET("/status", eduHandler.GetEduStatus)
		edu.POST("/courses", eduHandler.GetCourses)
		edu.POST("/grades", eduHandler.GetGrades)
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
	}

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
