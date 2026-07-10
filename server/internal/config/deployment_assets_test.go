package config

import (
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
)

// TestDeploymentAssetsSupportExamPaperUpload 防止部署脚本或反向代理阻断 20 MiB 试卷上传。
func TestDeploymentAssetsSupportExamPaperUpload(t *testing.T) {
	_, currentFile, _, ok := runtime.Caller(0)
	if !ok {
		t.Fatal("无法定位部署资产测试文件")
	}
	repoRoot := filepath.Clean(filepath.Join(filepath.Dir(currentFile), "..", "..", ".."))

	deployScript, err := os.ReadFile(filepath.Join(repoRoot, "deploy.sh"))
	if err != nil {
		t.Fatalf("读取部署脚本失败: %v", err)
	}
	deployScriptText := string(deployScript)
	if !strings.Contains(deployScriptText, `GO_VER="go1.25.0"`) ||
		!strings.Contains(deployScriptText, `"1.25" "$v"`) ||
		!strings.Contains(deployScriptText, `head -1)" = "1.25"`) {
		t.Fatal("部署脚本必须安装并要求 Go 1.25，以满足 server/go.mod 的 go 1.25.0 要求")
	}

	configSource, err := os.ReadFile(filepath.Join(repoRoot, "server", "internal", "config", "config.go"))
	if err != nil {
		t.Fatalf("读取配置源码失败: %v", err)
	}
	for _, placeholder := range []string{
		"dev-only-secret-do-not-use-in-production",
		"your-super-secret-jwt-key-change-this",
		"change_me_in_env",
	} {
		if !strings.Contains(string(configSource), placeholder) {
			t.Fatalf("config.go 必须继续拒绝 JWT 占位符 %q", placeholder)
		}
		if !strings.Contains(deployScriptText, placeholder) {
			t.Fatalf("deploy.sh 必须识别并轮换 config.go 拒绝的 JWT 占位符 %q", placeholder)
		}
	}

	deployDoc, err := os.ReadFile(filepath.Join(repoRoot, "DEPLOY.md"))
	if err != nil {
		t.Fatalf("读取部署文档失败: %v", err)
	}
	if !strings.Contains(string(deployDoc), "Go 1.25+") {
		t.Fatal("部署文档必须声明 Go 1.25+ 要求")
	}

	readme, err := os.ReadFile(filepath.Join(repoRoot, "README.md"))
	if err != nil {
		t.Fatalf("读取项目说明失败: %v", err)
	}
	if !strings.Contains(string(readme), "Go-1.25+") {
		t.Fatal("项目说明中的 Go 版本标识必须与 server/go.mod 保持一致")
	}

	nginxConfigs := make(map[string]string)
	for _, relativePath := range []string{"client/nginx.conf", "nginx/docker.conf"} {
		content, err := os.ReadFile(filepath.Join(repoRoot, relativePath))
		if err != nil {
			t.Fatalf("读取 Nginx 配置失败 (%s): %v", relativePath, err)
		}
		nginxConfigs[relativePath] = string(content)
		if !strings.Contains(string(content), "client_max_body_size 21m;") {
			t.Fatalf("%s 必须允许含 multipart 开销的 20 MiB 试卷上传", relativePath)
		}
	}
	if !strings.Contains(nginxConfigs["nginx/docker.conf"], "root /usr/share/nginx/html;") ||
		!strings.Contains(nginxConfigs["nginx/docker.conf"], "try_files $uri $uri/ /index.html;") ||
		strings.Contains(nginxConfigs["nginx/docker.conf"], "proxy_pass http://client:80") {
		t.Fatal("Docker Nginx 必须直接提供挂载的 Flutter Web 静态文件，不能代理不存在的 client 服务")
	}

	compose, err := os.ReadFile(filepath.Join(repoRoot, "docker-compose.yml"))
	if err != nil {
		t.Fatalf("读取 Docker Compose 配置失败: %v", err)
	}
	composeText := string(compose)
	if !strings.Contains(composeText, "services:\n") ||
		!strings.Contains(composeText, "\n  nginx:\n") ||
		strings.Contains(composeText, "networks:\n  shenliyuan_network:\n    driver: bridge\n\n  nginx:") {
		t.Fatal("Docker Compose 必须将 nginx 定义为服务，而不能错误地放在 networks 下")
	}

	composeEnvExample, err := os.ReadFile(filepath.Join(repoRoot, ".env.example"))
	if err != nil {
		t.Fatalf("Docker Compose 必须提供根目录 .env.example，便于复制为 .env: %v", err)
	}
	composeEnvText := string(composeEnvExample)
	for _, key := range []string{
		"DB_PASSWORD=",
		"JWT_SECRET=",
		"SUPER_ADMIN_ID=",
		"SUPER_ADMIN_PASSWORD=",
	} {
		if !strings.Contains(composeEnvText, key) {
			t.Fatalf("根目录 .env.example 必须包含 Docker Compose 所需变量 %s", key)
		}
	}

	dockerfile, err := os.ReadFile(filepath.Join(repoRoot, "server", "Dockerfile"))
	if err != nil {
		t.Fatalf("读取服务端 Dockerfile 失败: %v", err)
	}
	dockerfileText := string(dockerfile)
	if !strings.Contains(dockerfileText, `ENV DSN="host=postgres port=5432 user=postgres password=change_me_in_env dbname=shenliyuan sslmode=disable"`) {
		t.Fatal("Dockerfile 中带空格的 DSN 必须用引号作为单个环境变量值")
	}
	if !strings.Contains(dockerfileText, "chmod 0700 /app/private /app/private/exam-papers") {
		t.Fatal("Dockerfile 必须同时收紧 /app/private 父目录和试卷私有目录权限")
	}
}
