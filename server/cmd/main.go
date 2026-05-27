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
    // 1. 拦截 fetch
    const originalFetch = window.fetch;
    window.fetch = async function(...args) {
        const response = await originalFetch.apply(this, args);
        const clone = response.clone(); 
        clone.json().then(data => {
            let jsonStr = JSON.stringify(data);
            // 排除无用的元数据请求（如 get_exam_info）
            if (jsonStr.includes('paper_count') && !jsonStr.includes('"options"')) return;
            // 匹配真正的题目特征
            if (jsonStr.includes('"options"') || jsonStr.includes('"problem_id"')) {
                console.log("AI助手 - 拦截到真实题目(fetch): " + (args[0] || ''));
                if (window.flutter_inappwebview && window.flutter_inappwebview.callHandler) {
                    window.flutter_inappwebview.callHandler('YuketangHelper', jsonStr);
                }
            }
        }).catch(e => {});
        return response;
    };

    // 2. 拦截 XMLHttpRequest
    const originalXHR = window.XMLHttpRequest;
    function newXHR() {
        const xhr = new originalXHR();
        const originalOpen = xhr.open;
        let currentUrl = '';
        xhr.open = function(method, url, ...args) {
            currentUrl = url;
            return originalOpen.apply(this, [method, url, ...args]);
        };
        xhr.addEventListener('load', function() {
            try {
                let jsonStr = xhr.responseText;
                if (jsonStr.includes('paper_count') && !jsonStr.includes('"options"')) return;
                if (jsonStr.includes('"options"') || jsonStr.includes('"problem_id"')) {
                    console.log("AI助手 - 拦截到真实题目(XHR): " + currentUrl);
                    if (window.flutter_inappwebview && window.flutter_inappwebview.callHandler) {
                        window.flutter_inappwebview.callHandler('YuketangHelper', jsonStr);
                    }
                }
            } catch(e) {}
        });
        return xhr;
    }
    window.XMLHttpRequest = newXHR;

    // 3. 终极无敌：DOM 直接抓取（如果网络请求没拦截到，或者题目写死在 HTML 里）
    function scrapeQuestionFromDOM() {
        // 尝试匹配雨课堂常见的题干和选项容器
        let questionBody = document.querySelector('.question-body, .problem-body, .title, .subject-title, .problem-title');
        let options = document.querySelectorAll('.option-item, .el-radio, .el-checkbox');
        
        if (questionBody && options.length > 0) {
            let qText = questionBody.innerText || '';
            let optText = Array.from(options).map(o => o.innerText).join('\n');
            let scrapedContent = qText + '\n选项:\n' + optText;
            
            // 确保不重复发送一样的题目（防止死循环）
            if (window.lastScraped === scrapedContent) return;
            window.lastScraped = scrapedContent;
            
            console.log("AI助手 - 从网页 DOM 抓取到题目");
            let scrapedData = {
                type: "网页直接抓取",
                content: scrapedContent
            };
            if (window.flutter_inappwebview && window.flutter_inappwebview.callHandler) {
                window.flutter_inappwebview.callHandler('YuketangHelper', JSON.stringify(scrapedData));
            }
        }
    }

    // 监听页面变化，自动触发 DOM 抓取
    const observer = new MutationObserver(() => {
        setTimeout(scrapeQuestionFromDOM, 500); // 稍微延迟，等 Vue 渲染完毕
    });
    observer.observe(document.body, { childList: true, subtree: true });
    setTimeout(scrapeQuestionFromDOM, 2000);

    // 4. 挂载到全局，供 Flutter 随时调用执行答案点击
    window.doAutoAnswer = function(answerStr, mode) {
        let optionLabels = document.querySelectorAll('.option-item, .el-radio, .el-checkbox'); 
        let submitBtn = document.querySelector('.submit-btn, .btn-submit');

        // 无差别自动选中答案
        optionLabels.forEach(label => {
            if(label.innerText.includes(answerStr)) {
                label.click(); // 模拟点击选中
                label.style.border = "2px solid #4CAF50"; // 给用户一个醒目的绿色高亮提示
            }
        });

        // 步骤 2：模式判断
        if (mode === 'full') {
            setTimeout(() => {
                if(submitBtn) {
                    submitBtn.click();
                }
            }, 1500); 
        } else {
            let toast = document.createElement('div');
            toast.innerText = '💡 AI 推荐答案: ' + answerStr + ' (点击此弹窗可关闭)';
            toast.style.cssText = "position:fixed; top:20px; left:50%; transform:translateX(-50%); background:rgba(0,0,0,0.85); color:white; padding:12px 20px; border-radius:12px; z-index:9999; max-width: 90%; word-wrap: break-word; font-size: 14px; box-shadow: 0 4px 12px rgba(0,0,0,0.3);";
            toast.onclick = function() { toast.remove(); };
            document.body.appendChild(toast);
            setTimeout(() => toast.remove(), 60000);
        }
    };
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
