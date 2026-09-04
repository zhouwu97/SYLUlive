package config

import (
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
)

// TestDeploymentAssetsSupportExamPaperUpload 防止部署脚本或反向代理阻断 20 MiB 试卷上传。
func TestDeploymentAssetsSupportExamPaperUpload(t *testing.T) {
	repoRoot := deploymentRepoRoot(t)

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
	composeEnvText := strings.ReplaceAll(string(composeEnvExample), "\r\n", "\n")
	for _, key := range []string{
		"DB_PASSWORD=",
		"JWT_SECRET=",
		"SUPER_ADMIN_ID=",
		"SUPER_ADMIN_PASSWORD=",
<<<<<<< HEAD
=======
		"ACCOUNT_IDENTITY_READ_MODE=legacy",
		"SCHOOL_AUTHORITY_RETIRED=true",
		"SCHOOL_DEVICE_CAPABILITY_CUT=true",
		"SCHOOL_ACADEMIC_ROUTES_RETIRED=true",
>>>>>>> origin/jiaowu
		"IMAGE_VARIANT_WORKER_ENABLED=",
		"AI_EXTERNAL_MCP_ENABLED=",
		"AI_EXTERNAL_MCP_TRANSPORT=",
		"AI_EXTERNAL_MCP_COMMAND=",
		"AI_EXTERNAL_MCP_TOOL_TIMEOUT_SECONDS=",
		"AI_EXTERNAL_MCP_MAX_CALLS_PER_RUN=",
	} {
		if !strings.Contains(composeEnvText, key) {
			t.Fatalf("根目录 .env.example 必须包含 Docker Compose 所需变量 %s", key)
		}
	}
	if !strings.Contains("\n"+composeEnvText, "\nAI_UNLIMITED_STUDENT_IDS=\n") {
		t.Fatal("根目录 .env.example 不得为任何账号预设不限额权限")
	}
	if !strings.Contains(composeText, "AI_UNLIMITED_STUDENT_IDS=${AI_UNLIMITED_STUDENT_IDS:-}") {
		t.Fatal("Docker Compose 的不限额账号默认值必须为空")
	}
<<<<<<< HEAD
=======
	if !strings.Contains(composeText, "ACCOUNT_IDENTITY_READ_MODE=${ACCOUNT_IDENTITY_READ_MODE:-legacy}") {
		t.Fatal("Docker Compose 的账号 Identity 读路径必须默认保持 legacy")
	}
	if strings.Count(composeText, "SCHOOL_AUTHORITY_RETIRED=${SCHOOL_AUTHORITY_RETIRED:?set SCHOOL_AUTHORITY_RETIRED=true in .env}") != 2 {
		t.Fatal("Docker Compose 必须向 Go 与 Python 教务服务传递学校能力总退役开关")
	}
	for _, expected := range []string{
		"SCHOOL_DEVICE_CAPABILITY_CUT=${SCHOOL_DEVICE_CAPABILITY_CUT:?set SCHOOL_DEVICE_CAPABILITY_CUT=true in .env}",
		"SCHOOL_ACADEMIC_ROUTES_RETIRED=${SCHOOL_ACADEMIC_ROUTES_RETIRED:?set SCHOOL_ACADEMIC_ROUTES_RETIRED=true in .env}",
	} {
		if !strings.Contains(composeText, expected) {
			t.Fatalf("Docker Compose 缺少可分阶段发布的学校能力退役项 %q", expected)
		}
	}
	serverEnvExample, err := os.ReadFile(filepath.Join(repoRoot, "server", ".env.example"))
	if err != nil {
		t.Fatalf("Go 服务必须提供退役开关示例配置: %v", err)
	}
	for _, key := range []string{
		"SCHOOL_AUTHORITY_RETIRED=true",
		"SCHOOL_DEVICE_CAPABILITY_CUT=true",
		"SCHOOL_ACADEMIC_ROUTES_RETIRED=true",
	} {
		if !strings.Contains(string(serverEnvExample), key) {
			t.Fatalf("server/.env.example 缺少学校能力退役项 %s", key)
		}
	}
>>>>>>> origin/jiaowu

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
	for _, expected := range []string{
		"AI_EXTERNAL_MCP_ENABLED=${AI_EXTERNAL_MCP_ENABLED:-false}",
		"AI_EXTERNAL_MCP_TRANSPORT=${AI_EXTERNAL_MCP_TRANSPORT:-ssh_stdio}",
		"AI_EXTERNAL_MCP_SSH_KEY_PATH=/run/secrets/mcp_ed25519",
		"AI_EXTERNAL_MCP_KNOWN_HOSTS_PATH=/run/secrets/mcp_known_hosts",
		"source: mcp_ssh_key",
		"source: mcp_known_hosts",
	} {
		if !strings.Contains(composeText, expected) {
			t.Fatalf("Docker Compose 缺少外部 MCP ssh_stdio 部署项 %q", expected)
		}
	}
	if !strings.Contains(dockerfileText, "openssh-client") {
		t.Fatal("server 镜像启用 ssh_stdio 前必须安装 openssh-client")
	}
}

// TestPublicUploadAccelDeploymentAssets 验证公开上传仍先经 Go 授权，再由 Nginx internal location 投递。
func TestPublicUploadAccelDeploymentAssets(t *testing.T) {
	repoRoot := deploymentRepoRoot(t)

	nginxText := readDeploymentAsset(t, repoRoot, "nginx", "docker.conf")
	composeText := strings.ReplaceAll(readDeploymentAsset(t, repoRoot, "docker-compose.yml"), "\r\n", "\n")
	deployDoc := readDeploymentAsset(t, repoRoot, "DEPLOY.md")
	mainSource := readDeploymentAsset(t, repoRoot, "server", "cmd", "main.go")

	if !strings.Contains(nginxText, "location ^~ /uploads/ {") {
		t.Fatal("公开上传必须使用明确的 /uploads/ 代理位置")
	}
	publicLocation := deploymentLocationBody(nginxText, "location ^~ /uploads/ {")
	for _, expected := range []string{
		"proxy_pass http://server:8080;",
		"proxy_set_header Host $host;",
		"proxy_set_header X-Real-IP $remote_addr;",
		"proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;",
		"proxy_set_header X-Forwarded-Proto $scheme;",
		"proxy_intercept_errors off;",
	} {
		if !strings.Contains(publicLocation, expected) {
			t.Errorf("公开上传代理位置缺少授权传输配置 %q", expected)
		}
	}
	for _, forbidden := range []string{"alias ", "root ", "try_files ", "return 200"} {
		if strings.Contains(publicLocation, forbidden) {
			t.Errorf("公开上传位置不得包含绕过 Go 授权的静态配置 %q", forbidden)
		}
	}

	if !strings.Contains(nginxText, "location ^~ /_internal/uploads/ {") {
		t.Fatal("必须存在专用的公开上传 internal location")
	}
	internalLocation := deploymentLocationBody(nginxText, "location ^~ /_internal/uploads/ {")
	for _, expected := range []string{
		"internal;",
		"alias /var/lib/sylulive/uploads/;",
		"disable_symlinks on from=/var/lib/sylulive/uploads/;",
		"autoindex off;",
		"sendfile on;",
		"aio threads;",
	} {
		if !strings.Contains(internalLocation, expected) {
			t.Errorf("internal 上传位置缺少安全或传输配置 %q", expected)
		}
	}
	if strings.Contains(internalLocation, "proxy_pass ") {
		t.Fatal("internal 上传位置必须由 Nginx 直接投递文件，不能再次代理")
	}

	serverBlock := deploymentServiceBody(t, composeText, "server")
	nginxBlock := deploymentServiceBody(t, composeText, "nginx")
	if !strings.Contains(serverBlock, "- server_data:/app/uploads") {
		t.Fatal("Go 服务必须挂载公开上传共享卷")
	}
	if !strings.Contains(nginxBlock, "- server_data:/var/lib/sylulive/uploads:ro") {
		t.Fatal("Nginx 只能以只读方式挂载公开上传共享卷")
	}
	if strings.Contains(nginxBlock, "exam_paper_data") || strings.Contains(nginxBlock, "competition_award_evidence_data") {
		t.Fatal("Nginx 不得挂载试卷或竞赛证明材料私有卷")
	}
	for _, expected := range []string{
		"UPLOAD_USE_ACCEL_REDIRECT=${UPLOAD_USE_ACCEL_REDIRECT:?set UPLOAD_USE_ACCEL_REDIRECT in .env}",
		"UPLOAD_ACCEL_PREFIX=${UPLOAD_ACCEL_PREFIX:-/_internal/uploads/}",
		"IMAGE_VARIANT_WORKER_ENABLED=${IMAGE_VARIANT_WORKER_ENABLED:?set IMAGE_VARIANT_WORKER_ENABLED in .env}",
	} {
		if !strings.Contains(serverBlock, expected) {
			t.Errorf("Go 服务图片管线开关必须由 .env 显式提供并固定内部前缀 %q", expected)
		}
	}
	if !strings.Contains(mainSource, "if cfg.ImageVariantWorkerEnabled {") ||
		!strings.Contains(mainSource, "services.StartImageVariantWorkers(appCtx, db, cfg.UploadDir, 1)") {
		t.Fatal("main.go 必须仅在 IMAGE_VARIANT_WORKER_ENABLED 开启时启动变体 worker")
	}

	for _, expected := range []string{
		"UPLOAD_USE_ACCEL_REDIRECT=false",
		"UPLOAD_ACCEL_PREFIX=/_internal/uploads/",
		"IMAGE_VARIANT_WORKER_ENABLED=false",
		"IMAGE_VARIANT_WORKER_ENABLED=true",
		"UPLOAD_USE_ACCEL_REDIRECT=true",
		"拒绝启动",
		"补偿任务",
		"仅在",
		"nginx -t",
		"P2 worker",
		"P3",
		"停 worker",
		"继续返回 origin URL",
		"不得删除文件",
		"private, no-store",
	} {
		if !strings.Contains(deployDoc, expected) {
			t.Errorf("部署文档缺少 P3 开关、发布或回退约束 %q", expected)
		}
	}
}

func deploymentLocationBody(config, marker string) string {
	start := strings.Index(config, marker)
	if start < 0 {
		return ""
	}
	remaining := config[start+len(marker):]
	if end := strings.Index(remaining, "\n    }"); end >= 0 {
		return remaining[:end]
	}
	return remaining
}

func deploymentServiceBody(t *testing.T, compose, service string) string {
	t.Helper()
	marker := "\n  " + service + ":\n"
	start := strings.Index(compose, marker)
	if start < 0 {
		t.Fatalf("Docker Compose 缺少服务 %q", service)
	}
	remaining := compose[start+len(marker):]
	lines := strings.Split(remaining, "\n")
	for index, line := range lines {
		if index == 0 {
			continue
		}
		if strings.HasPrefix(line, "  ") && !strings.HasPrefix(line, "    ") && strings.HasSuffix(line, ":") {
			return strings.Join(lines[:index], "\n")
		}
	}
	return remaining
}

// TestPaperStorageDeploymentAssets 验证文件服务部署资产维持最小权限、私有文件和密钥隔离边界。
func TestPaperStorageDeploymentAssets(t *testing.T) {
	repoRoot := deploymentRepoRoot(t)
	serviceText := readDeploymentAsset(t, repoRoot, "deploy", "paper-storage", "paper-storage.service")
	nginxText := readDeploymentAsset(t, repoRoot, "deploy", "paper-storage", "nginx.conf")
	bootstrapText := readDeploymentAsset(t, repoRoot, "deploy", "paper-storage", "nginx-bootstrap.conf")
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
		"listen 80 default_server;",
		"listen 443 ssl http2 default_server;",
		"server_name __PAPER_STORAGE_PUBLIC_IP__;",
		"return 301 https://__PAPER_STORAGE_PUBLIC_IP__$request_uri;",
		"location ^~ /.well-known/acme-challenge/",
		"root /var/lib/letsencrypt;",
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
	for _, expected := range []string{
		"listen 80 default_server;",
		"server_name __PAPER_STORAGE_PUBLIC_IP__;",
		"location ^~ /.well-known/acme-challenge/",
		"root /var/lib/letsencrypt;",
		"location / {",
		"return 404;",
	} {
		if !strings.Contains(bootstrapText, expected) {
			t.Errorf("Nginx bootstrap 配置缺少最小 ACME 项 %q", expected)
		}
	}
	for _, forbidden := range []string{"listen 443", "proxy_pass", "ssl_certificate"} {
		if strings.Contains(bootstrapText, forbidden) {
			t.Errorf("Nginx bootstrap 配置不得在证书签发前开放 %q", forbidden)
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
		"useradd",
		"chmod 0700",
		"chmod 0600",
		"SWAP_SIZE=${PAPER_STORAGE_SWAP_SIZE:-2G}",
		"fallocate -l \"$SWAP_SIZE\" \"$swap_new\"",
		"swapon \"$swap_path\"",
		"journalctl --vacuum-time=14d",
		"ufw allow \"${SSH_PORT}/tcp\"",
		"ufw allow 80/tcp",
		"ufw allow 443/tcp",
		"nginx -t",
		"systemctl daemon-reload",
		"systemctl reload nginx",
		"--render-nginx",
		"--render-bootstrap-nginx",
		"PAPER_STORAGE_PUBLIC_IP",
		"PAPER_STORAGE_TLS_CERT_PATH",
		"PAPER_STORAGE_TLS_KEY_PATH",
		"PAPER_STORAGE_ACME_MODE",
		"validate_public_ip",
		"validate_tls_certificate",
		"IP Address:",
		"openssl verify",
		"--ip-address \"$PUBLIC_IP\"",
		"--preferred-profile shortlived",
		"/var/lib/letsencrypt",
		"fullchain.pem",
		"privkey.pem",
		"nginx -t -c",
		"systemctl enable --now certbot.timer",
		"SSH_PORT=${SSH_PORT:-22}",
		"ALLOW_EXISTING_UFW_RULES",
		"ufw show added",
		"ufw default deny incoming",
		"ufw default allow outgoing",
		"[ -L \"$swap_path\" ]",
		"[ ! -f \"$swap_path\" ]",
		"${swap_path}.new",
		"blkid -p",
		"file -b",
		"sync \"$swap_new\"",
		"mv -f \"$swap_new\" \"$swap_path\"",
		"chown root:root \"$secure_path\"",
		"od -An -tx1 -N4",
		"paper-storage.new",
		"paper-storage.bak",
		"activate_binary_candidate",
	} {
		if !strings.Contains(installText, expected) {
			t.Errorf("文件服务安装脚本缺少幂等部署步骤 %q", expected)
		}
	}
	for _, expected := range []string{
		"__PAPER_STORAGE_TLS_CERTIFICATE__",
		"__PAPER_STORAGE_TLS_CERTIFICATE_KEY__",
		"__PAPER_STORAGE_PUBLIC_IP__",
	} {
		if !strings.Contains(nginxText, expected) {
			t.Errorf("Nginx 模板缺少可幂等渲染的 TLS 占位符 %q", expected)
		}
	}
	if strings.Contains(installText, "ssl-cert-snakeoil") ||
		strings.Contains(installText, "certbot --nginx") ||
		strings.Contains(installText, "-d sylulive.online") {
		t.Error("文件服务器不得回退临时证书或申请主业务域名证书")
	}
	for name, content := range map[string]string{
		"nginx":     nginxText,
		"bootstrap": bootstrapText,
		"install":   installText,
	} {
		if strings.Contains(content, "__PAPER_STORAGE_PUBLIC_HOST__") ||
			strings.Contains(content, "PAPER_STORAGE_PUBLIC_HOST") {
			t.Errorf("%s 仍包含已废弃的公网主机配置", name)
		}
		if strings.Contains(content, "sylulive.online") {
			t.Errorf("%s 不得复用 156 的业务域名", name)
		}
	}
	hookStart := strings.Index(installText, "'if nginx -t; then'")
	hookReload := strings.Index(installText, "'    systemctl reload nginx'")
	if hookStart < 0 || hookReload <= hookStart {
		t.Error("Certbot deploy hook 必须仅在 nginx -t 成功后 reload")
	}
	if !strings.Contains(installText, "mv -f \"$nginx_candidate\" /etc/nginx/nginx.conf") ||
		!strings.Contains(installText, "cp -p \"$nginx_previous\" /etc/nginx/nginx.conf") {
		t.Error("Nginx 配置必须原子替换，并在安装后校验失败时恢复上一版")
	}
	sshAllow := strings.Index(installText, "ufw allow \"${SSH_PORT}/tcp\"")
	denyIncoming := strings.Index(installText, "ufw default deny incoming")
	allowOutgoing := strings.Index(installText, "ufw default allow outgoing")
	webAllow := strings.Index(installText, "ufw allow 80/tcp")
	if sshAllow < 0 || denyIncoming <= sshAllow || allowOutgoing <= denyIncoming || webAllow <= allowOutgoing {
		t.Error("UFW 必须先放行已校验的 SSH 端口，再设置默认策略，最后放行 Web 端口")
	}
	ufwEnabled := strings.LastIndex(installText, "ufw --force enable")
	certificateRequest := strings.LastIndex(installText, "request_ip_certificate")
	if ufwEnabled < 0 || certificateRequest <= ufwEnabled {
		t.Error("ACME 申请必须晚于 UFW 放行 80/443")
	}
	binaryActivation := strings.LastIndex(installText, "activate_binary_candidate \"$binary_path\"")
	for _, prerequisite := range []string{"nginx -t", "prepare_swap_file", "ufw --force enable", "systemctl daemon-reload", "systemctl enable --now certbot.timer"} {
		if prerequisiteIndex := strings.LastIndex(installText, prerequisite); prerequisiteIndex < 0 || binaryActivation <= prerequisiteIndex {
			t.Errorf("二进制原子切换必须晚于前置部署步骤 %q", prerequisite)
		}
	}
	for _, forbidden := range []string{"156.233.229.232", "PAPER_STORAGE_SIGNING_SECRET=change-me", "PAPER_STORAGE_RECEIPT_SECRET=change-me"} {
		for name, content := range map[string]string{"systemd": serviceText, "nginx": nginxText, "env": envText, "install": installText} {
			if strings.Contains(content, forbidden) {
				t.Errorf("%s 部署资产不得包含服务器地址或弱生产密钥 %q", name, forbidden)
			}
		}
	}

	for _, expected := range []string{
		"139.196.148.174",
		"IP Address:139.196.148.174",
		"PAPER_STORAGE_ACME_MODE=external",
		"PAPER_STORAGE_TLS_CERT_PATH",
		"Cloudflare",
		"不得为 `/v1/files/*`",
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
		"SSH_PORT",
		"ALLOW_EXISTING_UFW_RULES=1",
		"default deny incoming",
		"paper-storage.new",
		"自动恢复",
	} {
		if !strings.Contains(deployDoc, expected) {
			t.Errorf("部署文档缺少文件服务运维说明 %q", expected)
		}
	}
}

// TestPaperStorageNginxRendererRequiresTrustedIPCertificate 验证正式配置只接受受信任的 IP SAN 证书。
func TestPaperStorageNginxRendererRequiresTrustedIPCertificate(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("Windows 环境没有 POSIX sh；Linux CI 和部署环境执行本测试")
	}
	if _, err := exec.LookPath("openssl"); err != nil {
		t.Skip("测试环境缺少 openssl")
	}
	repoRoot := deploymentRepoRoot(t)
	installScript := filepath.Join(repoRoot, "deploy", "paper-storage", "install.sh")
	template := filepath.Join(repoRoot, "deploy", "paper-storage", "nginx.conf")
	bootstrapTemplate := filepath.Join(repoRoot, "deploy", "paper-storage", "nginx-bootstrap.conf")
	tempDir := t.TempDir()
	output := filepath.Join(tempDir, "nginx-rendered.conf")
	caKey := filepath.Join(tempDir, "ca.key")
	caCert := filepath.Join(tempDir, "ca.pem")
	leafKey := filepath.Join(tempDir, "leaf.key")
	leafCSR := filepath.Join(tempDir, "leaf.csr")
	leafCert := filepath.Join(tempDir, "leaf.pem")
	fullchain := filepath.Join(tempDir, "fullchain.pem")
	extFile := filepath.Join(tempDir, "leaf.ext")

	runOpenSSL := func(args ...string) {
		t.Helper()
		command := exec.Command("openssl", args...)
		if combined, err := command.CombinedOutput(); err != nil {
			t.Fatalf("生成测试证书失败: openssl %v: %v\n%s", args, err, combined)
		}
	}
	runOpenSSL("genrsa", "-out", caKey, "2048")
	runOpenSSL("req", "-x509", "-new", "-key", caKey, "-sha256", "-days", "30", "-subj", "/CN=Paper Storage Test CA", "-out", caCert)
	runOpenSSL("genrsa", "-out", leafKey, "2048")
	runOpenSSL("req", "-new", "-key", leafKey, "-subj", "/CN=139.196.148.174", "-out", leafCSR)
	if err := os.WriteFile(extFile, []byte("subjectAltName=IP:139.196.148.174\n"), 0600); err != nil {
		t.Fatal(err)
	}
	runOpenSSL("x509", "-req", "-in", leafCSR, "-CA", caCert, "-CAkey", caKey, "-CAcreateserial", "-out", leafCert, "-days", "7", "-sha256", "-extfile", extFile)
	leaf, err := os.ReadFile(leafCert)
	if err != nil {
		t.Fatal(err)
	}
	ca, err := os.ReadFile(caCert)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(fullchain, append(leaf, ca...), 0600); err != nil {
		t.Fatal(err)
	}

	missingCommand := exec.Command("sh", installScript, "--render-nginx", template, output)
	missingCommand.Env = append(os.Environ(),
		"PAPER_STORAGE_TLS_CERT_PATH="+filepath.Join(tempDir, "missing.pem"),
		"PAPER_STORAGE_TLS_KEY_PATH="+leafKey,
		"PAPER_STORAGE_SYSTEM_CA_BUNDLE="+caCert,
	)
	if err := missingCommand.Run(); err == nil {
		t.Fatal("正式配置不得在证书不存在时回退到临时证书")
	}

	bootstrapCommand := exec.Command("sh", installScript, "--render-bootstrap-nginx", bootstrapTemplate, output)
	if combined, err := bootstrapCommand.CombinedOutput(); err != nil {
		t.Fatalf("渲染 bootstrap 配置失败: %v\n%s", err, combined)
	}
	bootstrap := readDeploymentAsset(t, tempDir, "nginx-rendered.conf")
	if !strings.Contains(bootstrap, "server_name 139.196.148.174;") || strings.Contains(bootstrap, "listen 443") {
		t.Fatal("bootstrap 配置必须只为固定 IP 开放 HTTP challenge")
	}

	renderCommand := exec.Command("sh", installScript, "--render-nginx", template, output)
	renderCommand.Env = append(os.Environ(),
		"PAPER_STORAGE_TLS_CERT_PATH="+fullchain,
		"PAPER_STORAGE_TLS_KEY_PATH="+leafKey,
		"PAPER_STORAGE_SYSTEM_CA_BUNDLE="+caCert,
		"PAPER_STORAGE_TLS_MIN_VALIDITY_SECONDS=0",
	)
	if combined, err := renderCommand.CombinedOutput(); err != nil {
		t.Fatalf("受信任 IP 证书应能渲染正式配置: %v\n%s", err, combined)
	}
	rendered := readDeploymentAsset(t, tempDir, "nginx-rendered.conf")
	if !strings.Contains(rendered, "server_name 139.196.148.174;") ||
		!strings.Contains(rendered, fullchain) || strings.Contains(rendered, "sylulive.online") {
		t.Fatal("正式 Nginx 配置必须使用固定 IP 和已校验证书")
	}

	mismatchCommand := exec.Command("sh", installScript, "--validate-tls-certificate")
	mismatchCommand.Env = append(os.Environ(),
		"PAPER_STORAGE_TLS_CERT_PATH="+fullchain,
		"PAPER_STORAGE_TLS_KEY_PATH="+caKey,
		"PAPER_STORAGE_SYSTEM_CA_BUNDLE="+caCert,
		"PAPER_STORAGE_TLS_MIN_VALIDITY_SECONDS=0",
	)
	if err := mismatchCommand.Run(); err == nil {
		t.Fatal("证书和私钥不匹配时必须拒绝部署")
	}

	wrongLeaf := filepath.Join(tempDir, "wrong-san.pem")
	wrongFullchain := filepath.Join(tempDir, "wrong-san-fullchain.pem")
	if err := os.WriteFile(extFile, []byte("subjectAltName=DNS:sylulive.online\n"), 0600); err != nil {
		t.Fatal(err)
	}
	runOpenSSL("x509", "-req", "-in", leafCSR, "-CA", caCert, "-CAkey", caKey, "-CAserial", filepath.Join(tempDir, "ca.srl"), "-out", wrongLeaf, "-days", "7", "-sha256", "-extfile", extFile)
	wrongLeafBytes, err := os.ReadFile(wrongLeaf)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(wrongFullchain, append(wrongLeafBytes, ca...), 0600); err != nil {
		t.Fatal(err)
	}
	wrongSANCommand := exec.Command("sh", installScript, "--validate-tls-certificate")
	wrongSANCommand.Env = append(os.Environ(),
		"PAPER_STORAGE_TLS_CERT_PATH="+wrongFullchain,
		"PAPER_STORAGE_TLS_KEY_PATH="+leafKey,
		"PAPER_STORAGE_SYSTEM_CA_BUNDLE="+caCert,
		"PAPER_STORAGE_TLS_MIN_VALIDITY_SECONDS=0",
	)
	if err := wrongSANCommand.Run(); err == nil {
		t.Fatal("SAN 不包含文件服务器 IP 时必须拒绝部署")
	}
}

// TestPaperStorageInstallerValidatesFirewallRules 验证安装脚本拒绝无效 SSH 端口和意外放行规则。
func TestPaperStorageInstallerValidatesFirewallRules(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("Windows 环境没有 POSIX sh；Linux CI 和部署环境执行本测试")
	}
	repoRoot := deploymentRepoRoot(t)
	installScript := filepath.Join(repoRoot, "deploy", "paper-storage", "install.sh")
	for _, publicIP := range []string{"", "https://139.196.148.174", "139.196.148.174:443", "sylulive.online", "256.1.1.1", "1.2.3"} {
		command := exec.Command("sh", installScript, "--validate-public-ip", publicIP)
		if err := command.Run(); err == nil {
			t.Errorf("非法公网 IPv4 %q 必须被拒绝", publicIP)
		}
	}
	validIPCommand := exec.Command("sh", installScript, "--validate-public-ip", "139.196.148.174")
	if combined, err := validIPCommand.CombinedOutput(); err != nil {
		t.Fatalf("固定文件服务器 IP 被拒绝: %v\n%s", err, combined)
	}

	for _, port := range []string{"", "0", "65536", "22x", "-1"} {
		command := exec.Command("sh", installScript, "--validate-ssh-port", port)
		if err := command.Run(); err == nil {
			t.Errorf("无效 SSH 端口 %q 必须被拒绝", port)
		}
	}
	for _, port := range []string{"1", "22", "65535"} {
		command := exec.Command("sh", installScript, "--validate-ssh-port", port)
		if combined, err := command.CombinedOutput(); err != nil {
			t.Errorf("有效 SSH 端口 %q 被拒绝: %v\n%s", port, err, combined)
		}
	}

	stubDir := t.TempDir()
	ufwStub := filepath.Join(stubDir, "ufw")
	writeExecutableTestScript(t, ufwStub, "#!/bin/sh\nprintf '%s\\n' 'Added user rules:' 'ufw allow 22/tcp' 'ufw allow 80/tcp' 'ufw allow 443/tcp' 'ufw allow 9000/tcp'\n")
	command := exec.Command("sh", installScript, "--audit-ufw")
	command.Env = append(os.Environ(), "PATH="+stubDir+string(os.PathListSeparator)+os.Getenv("PATH"), "SSH_PORT=22")
	if err := command.Run(); err == nil {
		t.Fatal("存在意外 ALLOW 规则时安装脚本必须中止")
	}
	command = exec.Command("sh", installScript, "--audit-ufw")
	command.Env = append(os.Environ(), "PATH="+stubDir+string(os.PathListSeparator)+os.Getenv("PATH"), "SSH_PORT=22", "ALLOW_EXISTING_UFW_RULES=1")
	if combined, err := command.CombinedOutput(); err != nil {
		t.Fatalf("显式确认后应保留已有规则: %v\n%s", err, combined)
	}
}

// TestPaperStorageInstallerRebuildsSwapSafely 验证损坏 Swap 原子重建且拒绝符号链接。
func TestPaperStorageInstallerRebuildsSwapSafely(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("Windows 环境没有 POSIX sh；Linux CI 和部署环境执行本测试")
	}
	for _, commandName := range []string{"fallocate", "mkswap", "blkid", "file"} {
		if _, err := exec.LookPath(commandName); err != nil {
			t.Skipf("缺少部署环境命令 %s", commandName)
		}
	}
	repoRoot := deploymentRepoRoot(t)
	installScript := filepath.Join(repoRoot, "deploy", "paper-storage", "install.sh")
	tempDir := t.TempDir()
	swapPath := filepath.Join(tempDir, "swapfile")
	fstabPath := filepath.Join(tempDir, "fstab")
	swapsPath := filepath.Join(tempDir, "swaps")
	if err := os.WriteFile(swapPath, []byte("interrupted"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(fstabPath, []byte(swapPath+" none swap sw 0 0\n"+swapPath+" none swap sw 0 0\n"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(swapsPath, []byte("Filename Type Size Used Priority\n"), 0600); err != nil {
		t.Fatal(err)
	}
	command := exec.Command("sh", installScript, "--prepare-swap", swapPath)
	command.Env = append(os.Environ(),
		"PAPER_STORAGE_SWAP_SIZE=1M",
		"PAPER_STORAGE_FSTAB="+fstabPath,
		"PAPER_STORAGE_SWAPS_FILE="+swapsPath,
		"PAPER_STORAGE_SKIP_OWNERSHIP=1",
		"PAPER_STORAGE_SKIP_SWAPON=1",
	)
	if combined, err := command.CombinedOutput(); err != nil {
		t.Fatalf("原子重建损坏 Swap 失败: %v\n%s", err, combined)
	}
	blkid := exec.Command("blkid", "-p", "-s", "TYPE", "-o", "value", swapPath)
	if output, err := blkid.Output(); err != nil || strings.TrimSpace(string(output)) != "swap" {
		t.Fatalf("重建文件缺少 Swap 签名: %v, %q", err, output)
	}
	if _, err := os.Stat(swapPath + ".new"); !os.IsNotExist(err) {
		t.Fatal("原子重建成功后不得残留 .new 文件")
	}
	fstab := readDeploymentAsset(t, tempDir, "fstab")
	if strings.Count(fstab, swapPath+" none swap sw 0 0") != 1 {
		t.Fatalf("fstab 中 Swap 记录必须去重，实际内容: %q", fstab)
	}

	target := filepath.Join(tempDir, "target")
	linkedSwap := filepath.Join(tempDir, "linked-swap")
	if err := os.WriteFile(target, []byte("keep"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(target, linkedSwap); err != nil {
		t.Fatal(err)
	}
	command = exec.Command("sh", installScript, "--prepare-swap", linkedSwap)
	command.Env = append(os.Environ(), "PAPER_STORAGE_FSTAB="+fstabPath, "PAPER_STORAGE_SWAPS_FILE="+swapsPath)
	if err := command.Run(); err == nil {
		t.Fatal("Swap 符号链接必须被拒绝")
	}
	if content, err := os.ReadFile(target); err != nil || string(content) != "keep" {
		t.Fatal("拒绝符号链接时不得修改链接目标")
	}
}

// TestPaperStorageInstallerRestoresBinaryAfterHealthFailure 验证新版本健康检查失败时恢复旧二进制。
func TestPaperStorageInstallerRestoresBinaryAfterHealthFailure(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("Windows 环境没有 POSIX sh；Linux CI 和部署环境执行本测试")
	}
	repoRoot := deploymentRepoRoot(t)
	installScript := filepath.Join(repoRoot, "deploy", "paper-storage", "install.sh")
	tempDir := t.TempDir()
	binaryPath := filepath.Join(tempDir, "paper-storage")
	if err := os.WriteFile(binaryPath, []byte("old-version"), 0755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(binaryPath+".new", []byte("bad-new-version"), 0755); err != nil {
		t.Fatal(err)
	}
	stubDir := filepath.Join(tempDir, "bin")
	if err := os.Mkdir(stubDir, 0700); err != nil {
		t.Fatal(err)
	}
	writeExecutableTestScript(t, filepath.Join(stubDir, "systemctl"), "#!/bin/sh\nexit 0\n")
	writeExecutableTestScript(t, filepath.Join(stubDir, "curl"), "#!/bin/sh\nexit 1\n")
	command := exec.Command("sh", installScript, "--activate-binary", binaryPath, "http://127.0.0.1/healthz")
	command.Env = append(os.Environ(),
		"PATH="+stubDir+string(os.PathListSeparator)+os.Getenv("PATH"),
		"PAPER_STORAGE_HEALTH_ATTEMPTS=1",
	)
	if err := command.Run(); err == nil {
		t.Fatal("新版本健康检查失败时安装命令必须返回失败")
	}
	content, err := os.ReadFile(binaryPath)
	if err != nil || string(content) != "old-version" {
		t.Fatalf("健康检查失败后未恢复旧二进制: %v, %q", err, content)
	}
	if _, err := os.Stat(binaryPath + ".bak"); !os.IsNotExist(err) {
		t.Fatal("恢复旧版本后不得残留 .bak")
	}
}

// TestPaperStorageInstallerWaitsForServiceReadiness 验证服务启动期间的短暂连接失败不会触发回滚。
func TestPaperStorageInstallerWaitsForServiceReadiness(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("Windows 环境没有 POSIX sh；Linux CI 和部署环境执行本测试")
	}
	repoRoot := deploymentRepoRoot(t)
	installScript := filepath.Join(repoRoot, "deploy", "paper-storage", "install.sh")
	tempDir := t.TempDir()
	binaryPath := filepath.Join(tempDir, "paper-storage")
	if err := os.WriteFile(binaryPath, []byte("old-version"), 0755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(binaryPath+".new", []byte("new-version"), 0755); err != nil {
		t.Fatal(err)
	}
	stubDir := filepath.Join(tempDir, "bin")
	if err := os.Mkdir(stubDir, 0700); err != nil {
		t.Fatal(err)
	}
	statePath := filepath.Join(tempDir, "curl-attempts")
	writeExecutableTestScript(t, filepath.Join(stubDir, "systemctl"), "#!/bin/sh\nexit 0\n")
	writeExecutableTestScript(t, filepath.Join(stubDir, "sleep"), "#!/bin/sh\nexit 0\n")
	writeExecutableTestScript(t, filepath.Join(stubDir, "curl"), `#!/bin/sh
count=0
if [ -f "$PAPER_STORAGE_CURL_STATE" ]; then
    count=$(cat "$PAPER_STORAGE_CURL_STATE")
fi
count=$((count + 1))
printf '%s\n' "$count" > "$PAPER_STORAGE_CURL_STATE"
[ "$count" -ge 3 ]
`)
	command := exec.Command("sh", installScript, "--activate-binary", binaryPath, "http://127.0.0.1/healthz")
	command.Env = append(os.Environ(),
		"PATH="+stubDir+string(os.PathListSeparator)+os.Getenv("PATH"),
		"PAPER_STORAGE_CURL_STATE="+statePath,
		"PAPER_STORAGE_HEALTH_ATTEMPTS=3",
	)
	if output, err := command.CombinedOutput(); err != nil {
		t.Fatalf("服务就绪前的短暂失败不应触发回滚: %v, %s", err, output)
	}
	content, err := os.ReadFile(binaryPath)
	if err != nil || string(content) != "new-version" {
		t.Fatalf("服务就绪后未保留新二进制: %v, %q", err, content)
	}
	attempts, err := os.ReadFile(statePath)
	if err != nil || strings.TrimSpace(string(attempts)) != "3" {
		t.Fatalf("健康检查没有按预期重试: %v, %q", err, attempts)
	}
}

func writeExecutableTestScript(t *testing.T, path, content string) {
	t.Helper()
	if err := os.WriteFile(path, []byte(content), 0700); err != nil {
		t.Fatalf("写入测试脚本失败: %v", err)
	}
}

func deploymentRepoRoot(t *testing.T) string {
	t.Helper()
	if override := strings.TrimSpace(os.Getenv("PAPER_STORAGE_TEST_REPO_ROOT")); override != "" {
		return filepath.Clean(override)
	}
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
