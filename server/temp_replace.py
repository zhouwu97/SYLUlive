import os

path = 'e:/AI/xynewui/server/cmd/main.go'
with open(path, 'r', encoding='utf-8') as f:
    content = f.read()

# 1. Add time/tzdata
content = content.replace('"strings"\n', '"strings"\n\t_ "time/tzdata"\n')

# 2. Add AutoMigrate models
content = content.replace('&models.LotteryParticipant{},\n', '&models.LotteryParticipant{},\n\t\t&models.CachedQuestion{},\n\t\t&models.SystemConfig{},\n')

# 3. Add Handlers
old_handlers = 'tutorialHandler := handlers.NewTutorialHandler(db)'
new_handlers = 'tutorialHandler := handlers.NewTutorialHandler(db)\n\taiSolveHandler := handlers.NewAiSolveHandler(db, cfg.DeepSeekAPIKey, cfg.DeepSeekBaseURL)\n\tconfigHandler := handlers.NewConfigHandler(db)'
content = content.replace(old_handlers, new_handlers)

# 4. Add Routes
old_routes = 'auth.POST("/change_password", middleware.AuthMiddleware(db, cfg.JWTSecret), authHandler.ChangePassword)\n\t}'
new_routes = old_routes + '\n\n\t// 公共配置路由，无需 JWT 鉴权\n\tpublicGroup := r.Group("/api/v1/config")\n\t{\n\t\tpublicGroup.GET("/inject-script", configHandler.GetInjectScript)\n\t}\n\n\t// AI 答题路由\n\tai := r.Group("/api/v1/question")\n\tai.Use(middleware.AuthMiddleware(db, cfg.JWTSecret))\n\t{\n\t\tai.POST("/solve", aiSolveHandler.Solve)\n\t}'
content = content.replace(old_routes, new_routes)

# 5. Add ensureInjectScript call
content = content.replace('ensureSystemSuperAdmin(db, cfg.SuperAdminID, cfg.SuperAdminPass)\n\n\tr := gin.Default()', 'ensureSystemSuperAdmin(db, cfg.SuperAdminID, cfg.SuperAdminPass)\n\n\t// 确保雨课堂 JS 注入脚本存在\n\tensureInjectScript(db)\n\n\tr := gin.Default()')

# 6. Add ensureInjectScript func
ensure_func = '''
// ensureInjectScript 确保数据库里有一份基础的拦截脚本
func ensureInjectScript(db *gorm.DB) {
\tvar config models.SystemConfig
\tif err := db.Where("config_key = ?", "yuketang_inject_js").First(&config).Error; err != nil {
\t\tjsCode := `(function() {
    const originalFetch = window.fetch;
    window.fetch = async function(...args) {
        const response = await originalFetch.apply(this, args);
        
        // 克隆一份响应用于读取，避免消耗掉原始的数据流
        const clone = response.clone(); 
        
        // 假设雨课堂获取题目的接口路径包含 "get_student_presentation" 或 "problem"
        if (args[0] && typeof args[0] === 'string' && args[0].includes('problem')) {
            clone.json().then(data => {
                // 将拦截到的题目 JSON 转化为字符串，通过约定好的 Channel 传给 Flutter
                if (window.flutter_inappwebview && window.flutter_inappwebview.callHandler) {
                    window.flutter_inappwebview.callHandler('YuketangHelper', JSON.stringify(data));
                }
            }).catch(e => console.error("解析题目JSON失败", e));
        }
        return response;
    };
})();`
\t\tdb.Create(&models.SystemConfig{
\t\t\tConfigKey:   "yuketang_inject_js",
\t\t\tConfigValue: jsCode,
\t\t\tDescription: "雨课堂默认题目拦截脚本",
\t\t})
\t}
}
'''
content = content + ensure_func

with open(path, 'w', encoding='utf-8') as f:
    f.write(content)

print('Success')
