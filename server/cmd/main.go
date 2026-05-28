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
        
        getTotalQuestions: function() {
            if (!window.__aiExamData) return 0;
            let rawObj = JSON.parse(window.__aiExamData);
            let count = 0;
            let recurse = (o, depth) => {
                if (depth > 15) return;
                if (Array.isArray(o)) {
                    if (o.length > 0 && typeof o[0] === 'object' && o[0] !== null && (o[0].options || o[0].problem_id || o[0].content)) {
                        count += o.length;
                        return;
                    }
                    o.forEach(v => recurse(v, depth+1));
                } else if (typeof o === 'object' && o !== null) {
                    for (let k in o) recurse(o[k], depth+1);
                }
            };
            recurse(rawObj, 0);
            return count;
        },
        
        sliceExamData: function(rangeStr) {
            if (!window.__aiExamData) return null;
            let indices = this.parseRange(rangeStr);
            let rawObj = JSON.parse(window.__aiExamData);
            
            let safeSlice = (obj, idx) => {
                let recurse = (o, i, depth) => {
                    if (depth > 15) return o;
                    if (Array.isArray(o)) {
                        if (o.length > 0 && typeof o[0] === 'object' && o[0] !== null && (o[0].options || o[0].problem_id || o[0].content)) {
                            let filtered = [];
                            for (let j=0; j<o.length; j++) {
                                if (i.length === 0 || i.includes(window.__aiGlobalIndex)) {
                                    let copy = Object.assign({}, o[j]);
                                    copy.__originalIndex = window.__aiGlobalIndex;
                                    filtered.push(copy);
                                }
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
            return JSON.stringify(slicedObj);
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
                return;
            }

            if (mode === 'full') {
                 let lines = answerStr.split('\\n');
                 let optionLabels = document.querySelectorAll('.option-item, .el-radio, .el-checkbox, .live-option-btn'); 
                 
                 lines.forEach(line => {
                     // 剔除所有题号、选项前缀 (如 "1. ", "17. ", "A. ", "A、", "A: " 等)
                     // 正则解释：匹配开头的数字或单个字母，后面跟着点、顿号、冒号或空格
                     let cleanAnswer = line.replace(/^(?:\\d+|[A-Z])[\\.\\:、\\s]+/, '').trim();
                     if (!cleanAnswer) return;
                     
                     optionLabels.forEach(label => {
                         // 在对比时，也将网页上 DOM 的文本稍微清理一下前缀再比对，防止网页里的 "C. " 干扰
                         let cleanLabel = label.innerText.replace(/^(?:\\d+|[A-Z])[\\.\\:、\\s]+/, '').trim();
                         // 只要包含核心文字就点击！彻底无视 A/B/C/D 的乱序错位
                         if(cleanLabel.includes(cleanAnswer) || cleanAnswer.includes(cleanLabel)) {
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
