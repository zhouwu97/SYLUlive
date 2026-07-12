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
	composeText := strings.ReplaceAll(string(compose), "\r\n", "\n")
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

// TestPaperStorageDeploymentAssets 验证文件服务部署资产维持最小权限、私有文件和密钥隔离边界。
func TestPaperStorageDeploymentAssets(t *testing.T) {
	repoRoot := deploymentRepoRoot(t)
	serviceText := readDeploymentAsset(t, repoRoot, "deploy", "paper-storage", "paper-storage.service")
	nginxText := readDeploymentAsset(t, repoRoot, "deploy", "paper-storage", "nginx.conf")
	envText := readDeploymentAsset(t, repoRoot, "deploy", "paper-storage", "paper-storage.env.example")
	installText := readDeploymentAsset(t, repoRoot, "deploy", "paper-storage", "install.sh")
	deployDoc := readDeploymentAsset(t, repoRoot, "DEPLOY.md")

	for _, expected := range []string{
		"User=paper-storage",
		"Group=paper-storage",
		"EnvironmentFile=/etc/sylg-paper-storage.env",
		"ExecStart=/opt/sylg-paper-storage/bin/paper-storage",
		"Restart=on-failure",
		"NoNewPrivileges=true",
		"PrivateTmp=true",
		"ProtectSystem=strict",
		"ProtectHome=true",
		"ReadWritePaths=/opt/sylg-paper-storage/data",
		"UMask=0077",
		"TimeoutStopSec=15s",
	} {
		if !strings.Contains(serviceText, expected) {
			t.Errorf("systemd 文件服务缺少加固项 %q", expected)
		}
	}

	for _, expected := range []string{
		"user paper-storage;",
		"server_name sylulive.online;",
		"server_name www.sylulive.online;",
		"return 301 https://sylulive.online$request_uri;",
		"client_max_body_size 21m;",
		"proxy_request_buffering off;",
		"proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;",
		"proxy_set_header X-Forwarded-Proto $scheme;",
		"location /_paper_files/",
		"internal;",
		"alias /opt/sylg-paper-storage/data/exam-papers/;",
		"add_header Cache-Control \"private, no-store\" always;",
		"add_header Referrer-Policy \"no-referrer\" always;",
		"autoindex off;",
		"access_log off;",
	} {
		if !strings.Contains(nginxText, expected) {
			t.Errorf("Nginx 文件服务缺少安全或流量配置 %q", expected)
		}
	}
	for _, route := range []string{"/healthz", "/v1/uploads/", "/v1/files/", "/internal/v1/"} {
		if !strings.Contains(nginxText, "location "+route) {
			t.Errorf("Nginx 文件服务必须代理公开服务路由 %s", route)
		}
	}

	for _, key := range []string{
		"PAPER_STORAGE_LISTEN=",
		"PAPER_STORAGE_DIR=",
		"PAPER_STORAGE_SIGNING_SECRET=",
		"PAPER_STORAGE_RECEIPT_SECRET=",
		"PAPER_STORAGE_MAX_CONCURRENT_VALIDATIONS=",
	} {
		if !strings.Contains(envText, key) {
			t.Errorf("文件服务环境变量示例缺少 %s", key)
		}
	}
	if !strings.Contains(envText, "PAPER_STORAGE_SIGNING_SECRET=CHANGE_ME_SIGNING_SECRET") ||
		!strings.Contains(envText, "PAPER_STORAGE_RECEIPT_SECRET=CHANGE_ME_RECEIPT_SECRET") {
		t.Error("文件服务环境变量示例必须使用两把不同且不能通过长度校验的密钥占位符")
	}

	for _, expected := range []string{
		"apt-get install",
		"nginx",
		"ufw",
		"certbot",
		"python3-certbot-nginx",
		"useradd",
		"chmod 0700",
		"chmod 0600",
		"fallocate -l 2G /swapfile",
		"swapon /swapfile",
		"journalctl --vacuum-time=14d",
		"ufw allow 22/tcp",
		"ufw allow 80/tcp",
		"ufw allow 443/tcp",
		"nginx -t",
		"systemctl daemon-reload",
		"systemctl reload nginx",
	} {
		if !strings.Contains(installText, expected) {
			t.Errorf("文件服务安装脚本缺少幂等部署步骤 %q", expected)
		}
	}
	for _, forbidden := range []string{"139.196.148.174", "156.233.229.232", "PAPER_STORAGE_SIGNING_SECRET=change-me", "PAPER_STORAGE_RECEIPT_SECRET=change-me"} {
		for name, content := range map[string]string{"systemd": serviceText, "nginx": nginxText, "env": envText, "install": installText} {
			if strings.Contains(content, forbidden) {
				t.Errorf("%s 部署资产不得包含服务器地址或弱生产密钥 %q", name, forbidden)
			}
		}
	}

	for _, expected := range []string{
		"sylulive.online",
		"139.196.148.174",
		"Cloudflare",
		"绕过缓存",
		"每日磁盘快照",
		"保留 7 天",
		"openssl rand -hex 32",
		"certbot",
		"/healthz",
		"PasswordAuthentication no",
		"PermitRootLogin prohibit-password",
		"确认 SSH 公钥登录成功后",
		"回滚",
		"不得记录服务器密码",
	} {
		if !strings.Contains(deployDoc, expected) {
			t.Errorf("部署文档缺少文件服务运维说明 %q", expected)
		}
	}
}

func deploymentRepoRoot(t *testing.T) string {
	t.Helper()
	_, currentFile, _, ok := runtime.Caller(0)
	if !ok {
		t.Fatal("无法定位部署资产测试文件")
	}
	return filepath.Clean(filepath.Join(filepath.Dir(currentFile), "..", "..", ".."))
}

func readDeploymentAsset(t *testing.T, repoRoot string, pathParts ...string) string {
	t.Helper()
	content, err := os.ReadFile(filepath.Join(append([]string{repoRoot}, pathParts...)...))
	if err != nil {
		t.Fatalf("读取部署资产 %s 失败: %v", filepath.Join(pathParts...), err)
	}
	return string(content)
}
