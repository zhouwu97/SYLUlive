package main



import (

	"log"

	"net/http"

	"os"

	"strings"
	_ "time/tzdata"



	"github.com/gin-gonic/gin"

	"github.com/glebarez/sqlite"

	"golang.org/x/crypto/bcrypt"

	"gorm.io/driver/postgres"

	"gorm.io/gorm"

	"shenliyuan/internal/config"

	"shenliyuan/internal/handlers"

	"shenliyuan/internal/middleware"

	"shenliyuan/internal/models"

	"shenliyuan/internal/tasks"

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

		&models.Notification{},

		&models.CheckIn{},

		&models.ExpLog{},

		&models.LotteryEvent{},

		&models.LotteryParticipant{},
		&models.CachedQuestion{},
		&models.SystemConfig{},

	); err != nil {

		log.Fatal("数据库迁移失败:", err)

	}

	// 启动时自动修复可能不同步的评论数和点赞数
	log.Println("正在同步帖子评论数与点赞数...")
	db.Exec(`UPDATE posts SET reply_count = (SELECT COUNT(*) FROM replies WHERE replies.post_id = posts.id AND replies.status = 'normal')`)
	db.Exec(`UPDATE posts SET like_count = (SELECT COUNT(*) FROM likes WHERE likes.post_id = posts.id AND likes.target_type = 'post')`)
	log.Println("同步完成")

	// 确保默认超级管理员

	ensureSystemSuperAdmin(db, cfg.SuperAdminID, cfg.SuperAdminPass)

	// 确保雨课堂 JS 注入脚本存在
	ensureInjectScript(db)

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

	replyHandler := handlers.NewReplyHandler(db, cfg.JPushAppKey, cfg.JPushMasterSecret)

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
	aiSolveHandler := handlers.NewAiSolveHandler(db, cfg.DeepSeekAPIKey, cfg.DeepSeekBaseURL)
	configHandler := handlers.NewConfigHandler(db)

	teacherHandler := handlers.NewTeacherHandler(db)

	majorHandler := handlers.NewMajorHandler(db)

	feedbackHandler := handlers.NewFeedbackHandler(db)

	checkinHandler := handlers.NewCheckInHandler(db)

	notificationHandler := handlers.NewNotificationHandler(db)

	erkeHandler := handlers.NewErkeHandler(db)

	lotteryHandler := handlers.NewLotteryHandler(db)



	// 初始化教务服务配置

	handlers.EduServiceConfig.BaseURL = cfg.EduServiceURL

	handlers.VerifyCodeConfig.SMTPHost = cfg.SMTPHost

	handlers.VerifyCodeConfig.SMTPPort = cfg.SMTPPort

	handlers.VerifyCodeConfig.SMTPUser = cfg.SMTPUser

	handlers.VerifyCodeConfig.SMTPPass = cfg.SMTPPass

	handlers.VerifyCodeConfig.SMTPFrom = cfg.SMTPFrom

	handlers.SetMajorLogDB(db)



	// 启动后台定时任务

	tasks.StartLotteryCron(db)



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

		user.POST("/checkin", checkinHandler.DoCheckIn)

		user.GET("/checkin/status", checkinHandler.GetStatus)

		user.GET("/:id", userHandler.GetUserInfo)

	}



	// 帖子路由

	posts := r.Group("/api/posts")

	posts.Use(middleware.OptionalAuthMiddleware(db, cfg.JWTSecret))

	{

		posts.GET("", postHandler.GetList)

		posts.GET("/:id", postHandler.GetOne)

		posts.GET("/:id/replies", replyHandler.GetList)

	}

	postsAuth := r.Group("/api/posts")

	postsAuth.Use(middleware.AuthMiddleware(db, cfg.JWTSecret))

	{

		postsAuth.POST("", postHandler.Create)

		postsAuth.PUT("/:id", postHandler.Update)

		postsAuth.DELETE("/:id", postHandler.Delete)

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

		messages.DELETE("/conversations/:id", messageHandler.DeleteConversation)

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

		announcementsAuth.GET("/unread", announcementHandler.GetUnread)

		announcementsAuth.GET("/:id", announcementHandler.GetOne)

		announcementsAuth.POST("/:id/read", announcementHandler.MarkRead)

	}

	announcementsAdmin := announcements.Group("")

	announcementsAdmin.Use(middleware.AuthMiddleware(db, cfg.JWTSecret), middleware.AdminMiddleware())

	{

		announcementsAdmin.POST("", announcementHandler.Create)

		announcementsAdmin.PUT("/:id", announcementHandler.Update)

		announcementsAdmin.DELETE("/:id", announcementHandler.Delete)

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

		edu.POST("/pre_verify", eduHandler.PreVerify) // 注册前验证教务账号

	}



	// 超级管理员路由

	superAdmin := r.Group("/api/super")

	superAdmin.Use(middleware.AuthMiddleware(db, cfg.JWTSecret), middleware.SuperAdminMiddleware())

	{

		superAdmin.GET("/users", superAdminHandler.GetUsers)
		superAdmin.GET("/lottery/participants", superAdminHandler.GetLotteryParticipants)
		superAdmin.DELETE("/lottery/participants/:event_id/:user_id", superAdminHandler.KickLotteryParticipant)

		superAdmin.PUT("/users/:id/role", superAdminHandler.UpdateUserRole)

		superAdmin.PUT("/users/:id/credit", superAdminHandler.UpdateUserCredit)

		superAdmin.POST("/users/:id/reset_password", superAdminHandler.ResetUserPassword)

		superAdmin.DELETE("/users/:id", superAdminHandler.DeleteUser)

		superAdmin.GET("/stats", superAdminHandler.GetStatistics)

		superAdmin.GET("/admin_logs", superAdminHandler.GetAdminLogs)

		superAdmin.POST("/admin_logs/revoke_exp", superAdminHandler.RevokeAdminExp)

		superAdmin.GET("/ai_config", superAdminHandler.GetAiConfig)

		superAdmin.PUT("/ai_config", superAdminHandler.UpdateAiConfig)

		superAdmin.GET("/invitations/pending", invitationHandler.GetApprovalList)

		superAdmin.POST("/invitations/:id/approve", invitationHandler.Approve)

	}



	// 题库提取路由

	r.POST("/api/exam/extract", middleware.AuthMiddleware(db, cfg.JWTSecret), examHandler.Extract)



	// 二课查询路由

	r.POST("/api/erke/scores", middleware.AuthMiddleware(db, cfg.JWTSecret), erkeHandler.GetScores)



	// 用户反馈路由

	r.POST("/api/feedback", middleware.AuthMiddleware(db, cfg.JWTSecret), feedbackHandler.Submit)



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

	lotteryAdminGroup.Use(middleware.AuthMiddleware(db, cfg.JWTSecret), middleware.AdminMiddleware())

	{

		lotteryAdminGroup.POST("/:id/draw", lotteryHandler.Draw)

	}



	// 版本信息

	r.GET("/api/version", func(c *gin.Context) {

		c.JSON(http.StatusOK, gin.H{

			"version":             "1.4.0",

			"min_version":         "1.4.0", // 增加最低版本限制，低于此版本的客户端将被强制更新

			"force_update":        false, // 保留兼容旧版逻辑

			"download_url":        "https://github.com/zhouwu97/SYLUlive/releases",

			"github_download_url": "https://github.com/zhouwu97/SYLUlive/releases",

			"gitee_download_url":  "https://gitee.com/chunhezi/SYLUlive/releases",

			"update_msg":          "新版本可用，本次更新包含了重要功能，请务必更新。",

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



	// 确保 20052403060128 也是超级管理员

	db.Model(&models.User{}).

		Where("student_id = ?", "20052403060128").

		Update("role", models.RoleSuperAdmin)



	// 移除将其他超级管理员降级的代码，允许多个超级管理员共存

	// db.Model(&models.User{}).

	// 	Where("role = ? AND student_id <> ?", models.RoleSuperAdmin, studentID).

	// 	Update("role", models.RoleUser)



	db.Model(&models.User{}).

		Where("student_id = ? AND role = ?", "admin", models.RoleAdmin).

		Update("role", models.RoleUser)



	log.Printf("系统超级管理员已就绪: %s 和 20052403060128", studentID)

}


// 注意：每次重启服务均会重置该配置，如需永久修改请直接更改此处硬编码
// ensureInjectScript 确保数据库里有一份基础的拦截脚本
func ensureInjectScript(db *gorm.DB) {
		jsCode := `(function() {
    if (window.__aiExamData !== undefined) return;
    window.__aiExamData = null;
    window.__aiSnapshotBackedUp = false;

    function parseRange(str) {
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
    }

    function injectDashboard() {
        if (document.getElementById('ai-cheat-host')) return document.getElementById('ai-cheat-host')._dashInterface;
        const host = document.createElement('div');
        host.id = 'ai-cheat-host';
        host.style.cssText = 'position: fixed; top: 20px; left: 10px; width: calc(100% - 20px); max-width: 400px; z-index: 2147483647; pointer-events: none;';
        let shadow = host;
        if (host.attachShadow) {
            try {
                shadow = host.attachShadow({mode: 'closed'});
            } catch(e) {}
        }
        
        shadow.innerHTML = "" +
            "<style>" +
            "    :host { all: initial; }" +
            "    * { box-sizing: border-box; }" +
            "    .dashboard {" +
            "        pointer-events: auto;" +
            "        font-family: system-ui, -apple-system, sans-serif;" +
            "        background: rgba(20, 20, 25, 0.95);" +
            "        border: 1px solid rgba(255,255,255,0.15);" +
            "        backdrop-filter: blur(12px);" +
            "        color: white;" +
            "        border-radius: 12px;" +
            "        box-shadow: 0 10px 40px rgba(0,0,0,0.6);" +
            "        display: flex;" +
            "        flex-direction: column;" +
            "        overflow: hidden;" +
            "    }" +
            "    .header {" +
            "        padding: 12px 15px;" +
            "        background: rgba(255,255,255,0.08);" +
            "        border-bottom: 1px solid rgba(255,255,255,0.1);" +
            "        display: flex;" +
            "        justify-content: space-between;" +
            "        align-items: center;" +
            "        cursor: move;" +
            "        touch-action: none;" +
            "    }" +
            "    .header-title { font-size: 14px; font-weight: 600; color: #4CAF50; letter-spacing: 0.5px; }" +
            "    .header-actions span { margin-left: 15px; font-size: 12px; cursor: pointer; color: #aaa; transition: color 0.2s; }" +
            "    .header-actions span:hover { color: white; }" +
            "    .content { padding: 15px; display: block; }" +
            "    .status { font-size: 12px; color: #bbb; margin-bottom: 12px; }" +
            "    .input-group { display: flex; gap: 8px; margin-bottom: 15px; }" +
            "    .input-group input {" +
            "        flex: 1; background: rgba(0,0,0,0.4); border: 1px solid #444;" +
            "        border-radius: 6px; color: white; padding: 8px 12px; font-size: 13px;" +
            "        outline: none; transition: border-color 0.2s;" +
            "    }" +
            "    .input-group input:focus { border-color: #4CAF50; }" +
            "    .input-group button {" +
            "        background: #4CAF50; color: white; border: none; border-radius: 6px;" +
            "        padding: 0 16px; font-weight: 600; cursor: pointer; font-size: 13px;" +
            "        transition: background 0.2s;" +
            "    }" +
            "    .input-group button:active { background: #45a049; }" +
            "    .answer-area {" +
            "        max-height: 40vh; overflow-y: auto; font-size: 13px; line-height: 1.6;" +
            "        color: #eee; padding-right: 5px;" +
            "    }" +
            "    .answer-area::-webkit-scrollbar { width: 4px; }" +
            "    .answer-area::-webkit-scrollbar-thumb { background: #666; border-radius: 2px; }" +
            "</style>" +
            "<div class=\"dashboard\" id=\"dashboard\">" +
            "    <div class=\"header\" id=\"drag-handle\">" +
            "        <div class=\"header-title\">🤖 AI 外挂控制台</div>" +
            "        <div class=\"header-actions\">" +
            "            <span id=\"min-btn\">最小化 _</span>" +
            "        </div>" +
            "    </div>" +
            "    <div class=\"content\" id=\"main-content\">" +
            "        <div class=\"status\" id=\"status-text\">状态: 正在等待拦截试卷数据...</div>" +
            "        <div class=\"input-group\">" +
            "            <input type=\"text\" id=\"range-input\" placeholder=\"范围如 1-10, 留空全做\">" +
            "            <button id=\"upload-btn\">上传获取</button>" +
            "        </div>" +
            "        <div class=\"answer-area\" id=\"answer-area\">等待操作...</div>" +
            "    </div>" +
            "</div>";

        (document.body || document.documentElement).appendChild(host);

        const handle = shadow.getElementById('drag-handle');
        const minBtn = shadow.getElementById('min-btn');
        const content = shadow.getElementById('main-content');
        const statusText = shadow.getElementById('status-text');
        const rangeInput = shadow.getElementById('range-input');
        const uploadBtn = shadow.getElementById('upload-btn');
        const answerArea = shadow.getElementById('answer-area');

        let isDragging = false, startY = 0, startTop = 0, startX = 0, startLeft = 0;
        handle.addEventListener('touchstart', e => {
            isDragging = true;
            startY = e.touches[0].clientY;
            startX = e.touches[0].clientX;
            startTop = parseInt(window.getComputedStyle(host).top, 10) || 20;
            startLeft = parseInt(window.getComputedStyle(host).left, 10) || 10;
        });
        handle.addEventListener('touchmove', e => {
            if (!isDragging) return;
            host.style.top = (startTop + e.touches[0].clientY - startY) + 'px';
            host.style.left = (startLeft + e.touches[0].clientX - startX) + 'px';
            e.preventDefault();
        }, { passive: false });
        handle.addEventListener('touchend', () => isDragging = false);

        let isMin = false;
        minBtn.onclick = () => {
            isMin = !isMin;
            content.style.display = isMin ? 'none' : 'block';
            minBtn.innerText = isMin ? '展开 ⬜' : '最小化 _';
        };

        uploadBtn.onclick = () => {
            if (!window.__aiExamData) {
                statusText.innerText = '状态: 错误 - 未拦截到试卷数据！';
                statusText.style.color = '#ff4444';
                return;
            }
            statusText.innerText = '状态: 正在智能裁剪数据并发往 Flutter...';
            statusText.style.color = '#4CAF50';
            answerArea.innerHTML = '<span style="color:#aaa;">🚀 AI 正在深度思考中，请稍候...</span>';
            
            let rangeStr = rangeInput.value.trim();
            let indices = parseRange(rangeStr);
            let rawObj = JSON.parse(window.__aiExamData);
            
            let safeSlice = (obj, idx) => {
                let recurse = (o, i, depth) => {
                    if (depth > 15) return o;
                    if (Array.isArray(o)) {
                        if (o.length > 0 && typeof o[0] === 'object' && o[0] !== null && (o[0].options || o[0].problem_id || o[0].content)) {
                            let filtered = [];
                            for (let j=0; j<o.length; j++) {
                                if (i.length === 0 || i.includes(window.__aiGlobalIndex)) filtered.push(o[j]);
                                window.__aiGlobalIndex++;
                            }
                            return filtered;
                        }
                        return o.map(v => recurse(v, i, depth+1));
                    } else if (typeof o === 'object' && o !== null) {
                        let res = {};
                        for (let k in o) res[k] = recurse(o[k], i, depth+1);
                        return res;
                    }
                    return o;
                };
                window.__aiGlobalIndex = 1;
                return recurse(obj, idx, 0);
            };
            
            let slicedObj = safeSlice(rawObj, indices);
            let slicedJson = JSON.stringify(slicedObj);
            
            if (window.flutter_inappwebview && window.flutter_inappwebview.callHandler) {
                window.flutter_inappwebview.callHandler('YuketangManualUpload', slicedJson);
            }
        };

        window.updateAiStatus = function(msg) {
            statusText.innerText = '状态: ' + msg;
            statusText.style.color = '#2196F3';
        };

        window.doAutoAnswer = function(answerStr, mode) {
            statusText.innerText = '状态: ✅ 答案已就绪！';
            statusText.style.color = '#4CAF50';
            answerArea.innerHTML = answerStr.replace(/\\n/g, '<br>');
            if (mode === 'full') {
                 let optionLabels = document.querySelectorAll('.option-item, .el-radio, .el-checkbox'); 
                 optionLabels.forEach(label => {
                     if(label.innerText.includes(answerStr)) {
                         label.click(); label.style.border = "2px solid #4CAF50";
                     }
                 });
                 let submitBtn = document.querySelector('.submit-btn, .btn-submit');
                 if(submitBtn) setTimeout(() => submitBtn.click(), 1500);
            }
        };
        
        let dashInterface = { statusText };
        host._dashInterface = dashInterface;
        return dashInterface;
    }

    function handleIntercept(jsonStr) {
        window.__aiExamData = jsonStr;
        let dash = injectDashboard();
        if (dash) {
            dash.statusText.innerText = '状态: 🎯 拦截成功！请设置范围并上传';
            dash.statusText.style.color = '#4CAF50';
        }
        if (!window.__aiSnapshotBackedUp && window.flutter_inappwebview && window.flutter_inappwebview.callHandler) {
            window.flutter_inappwebview.callHandler('YuketangBackup', jsonStr);
            window.__aiSnapshotBackedUp = true;
        }
    }

    const originalFetch = window.fetch;
    window.fetch = async function(...args) {
        const response = await originalFetch.apply(this, args);
        const clone = response.clone(); 
        clone.json().then(data => {
            let jsonStr = JSON.stringify(data);
            if (jsonStr.includes('paper_count') && !jsonStr.includes('"options"')) return;
            if (jsonStr.includes('"options"') || jsonStr.includes('"problem_id"')) handleIntercept(jsonStr);
        }).catch(e => {});
        return response;
    };

    const originalXHR = window.XMLHttpRequest;
    function newXHR() {
        const xhr = new originalXHR();
        const originalOpen = xhr.open;
        xhr.open = function(method, url, ...args) {
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
                if (jsonStr.includes('paper_count') && !jsonStr.includes('"options"')) return;
                if (jsonStr.includes('"options"') || jsonStr.includes('"problem_id"')) handleIntercept(jsonStr);
            } catch(e) {
                console.error('XHR intercept error:', e);
            }
        });
        return xhr;
    }
    window.XMLHttpRequest = newXHR;
    
    if (document.readyState === 'complete' || document.readyState === 'interactive') {
        setTimeout(injectDashboard, 1000);
    } else {
        document.addEventListener('DOMContentLoaded', injectDashboard);
    }
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
