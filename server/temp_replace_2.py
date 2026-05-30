import os

path = 'e:/AI/xynewui/server/cmd/main.go'
with open(path, 'r', encoding='utf-8') as f:
    content = f.read()

# Try to find the auth group end
idx = content.find('auth.POST("/change_password"')
if idx != -1:
    end_idx = content.find('}', idx)
    if end_idx != -1:
        # We replace after the '}'
        insert_text = '''

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
	}'''
        content = content[:end_idx+1] + insert_text + content[end_idx+1:]

with open(path, 'w', encoding='utf-8') as f:
    f.write(content)

print('Routes added')
