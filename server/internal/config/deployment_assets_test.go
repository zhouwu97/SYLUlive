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
		"PAPER_STORAGE_LETSENCRYPT_LIVE_DIR",
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
	} {
		if !strings.Contains(nginxText, expected) {
			t.Errorf("Nginx 模板缺少可幂等渲染的 TLS 占位符 %q", expected)
		}
	}
	if !strings.Contains(installText, "if has_lets_encrypt_certificate; then") ||
		!strings.Contains(installText, "elif [ -n \"${LETSENCRYPT_EMAIL:-}\" ]; then") {
		t.Error("已有 Let's Encrypt 证书时不得依赖邮箱或重新签发证书")
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
	binaryActivation := strings.LastIndex(installText, "activate_binary_candidate \"$binary_path\"")
	for _, prerequisite := range []string{"nginx -t", "prepare_swap_file", "ufw --force enable", "systemctl daemon-reload", "systemctl enable --now certbot.timer"} {
		if prerequisiteIndex := strings.LastIndex(installText, prerequisite); prerequisiteIndex < 0 || binaryActivation <= prerequisiteIndex {
			t.Errorf("二进制原子切换必须晚于前置部署步骤 %q", prerequisite)
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

// TestPaperStorageNginxRendererKeepsLetsEncryptCertificate 验证重复安装不会把正式证书退回临时证书。
func TestPaperStorageNginxRendererKeepsLetsEncryptCertificate(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("Windows 环境没有 POSIX sh；Linux CI 和部署环境执行本测试")
	}
	repoRoot := deploymentRepoRoot(t)
	installScript := filepath.Join(repoRoot, "deploy", "paper-storage", "install.sh")
	template := filepath.Join(repoRoot, "deploy", "paper-storage", "nginx.conf")
	tempDir := t.TempDir()
	liveDir := filepath.Join(tempDir, "letsencrypt", "live", "sylulive.online")
	output := filepath.Join(tempDir, "nginx-rendered.conf")

	render := func() string {
		t.Helper()
		command := exec.Command("sh", installScript, "--render-nginx", template, output)
		command.Env = append(os.Environ(), "PAPER_STORAGE_LETSENCRYPT_LIVE_DIR="+liveDir)
		if combined, err := command.CombinedOutput(); err != nil {
			t.Fatalf("渲染 Nginx 配置失败: %v\n%s", err, combined)
		}
		return readDeploymentAsset(t, tempDir, "nginx-rendered.conf")
	}

	first := render()
	if !strings.Contains(first, "/etc/ssl/certs/ssl-cert-snakeoil.pem") ||
		!strings.Contains(first, "/etc/ssl/private/ssl-cert-snakeoil.key") {
		t.Fatal("首次无正式证书时必须渲染 Ubuntu 临时证书")
	}

	if err := os.MkdirAll(liveDir, 0700); err != nil {
		t.Fatalf("创建模拟 Let's Encrypt 目录失败: %v", err)
	}
	for _, name := range []string{"fullchain.pem", "privkey.pem"} {
		if err := os.WriteFile(filepath.Join(liveDir, name), []byte("test"), 0600); err != nil {
			t.Fatalf("创建模拟证书 %s 失败: %v", name, err)
		}
	}
	upgraded := render()
	if !strings.Contains(upgraded, filepath.Join(liveDir, "fullchain.pem")) ||
		!strings.Contains(upgraded, filepath.Join(liveDir, "privkey.pem")) {
		t.Fatal("检测到正式证书后必须渲染 Let's Encrypt 证书路径")
	}
	if strings.Contains(upgraded, "ssl-cert-snakeoil") {
		t.Fatal("重复安装不得把正式证书回退为临时证书")
	}
}

// TestPaperStorageInstallerValidatesFirewallRules 验证安装脚本拒绝无效 SSH 端口和意外放行规则。
func TestPaperStorageInstallerValidatesFirewallRules(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("Windows 环境没有 POSIX sh；Linux CI 和部署环境执行本测试")
	}
	repoRoot := deploymentRepoRoot(t)
	installScript := filepath.Join(repoRoot, "deploy", "paper-storage", "install.sh")

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
	command.Env = append(os.Environ(), "PATH="+stubDir+string(os.PathListSeparator)+os.Getenv("PATH"))
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
