package handlers

import (
	"encoding/json"
	"log"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/go-rod/rod"
	"github.com/go-rod/rod/lib/launcher"
	"github.com/go-rod/rod/lib/proto"
)

// ExamExtractRequest 题库提取请求
type ExamExtractRequest struct {
	URL      string `json:"url" binding:"required"`      // 练习页面 URL
	Username string `json:"username" binding:"required"` // 登录账号
	Password string `json:"password" binding:"required"` // 登录密码
}

// ExamHandler 题库提取处理器
type ExamHandler struct {
	extractScript string // 注入的提取JS脚本
	browserPath   string // Chromium/Chrome 可执行文件路径
}

// NewExamHandler 创建题库提取处理器
func NewExamHandler() *ExamHandler {
	// 读取提取脚本
	script, err := os.ReadFile(filepath.Join("scripts", "exam_extract.js"))
	if err != nil {
		log.Printf("警告: 无法读取 exam_extract.js: %v", err)
	}

	// 查找 Chrome/Chromium
	browserPath := findBrowser()

	return &ExamHandler{
		extractScript: string(script),
		browserPath:   browserPath,
	}
}

// findBrowser 查找系统中可用的浏览器
func findBrowser() string {
	paths := []string{
		"C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe",
		"C:\\Program Files (x86)\\Google\\Chrome\\Application\\chrome.exe",
		"C:\\Program Files\\Microsoft\\Edge\\Application\\msedge.exe",
		"C:\\Program Files (x86)\\Microsoft\\Edge\\Application\\msedge.exe",
		"/usr/bin/google-chrome",
		"/usr/bin/google-chrome-stable",
		"/usr/bin/chromium-browser",
		"/usr/bin/chromium",
		"/snap/bin/chromium",
	}

	for _, p := range paths {
		if _, err := os.Stat(p); err == nil {
			return p
		}
	}

	// 尝试 which 命令
	if p, err := exec.LookPath("google-chrome"); err == nil {
		return p
	}
	if p, err := exec.LookPath("chromium"); err == nil {
		return p
	}
	if p, err := exec.LookPath("chrome"); err == nil {
		return p
	}

	// 默认让 Rod 自己找
	return ""
}

// Extract 执行题库提取
func (h *ExamHandler) Extract(c *gin.Context) {
	var req ExamExtractRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "参数错误: " + err.Error()})
		return
	}

	// 如果没有浏览器，返回错误
	if h.browserPath == "" {
		c.JSON(http.StatusInternalServerError, gin.H{
			"error": "未找到 Chrome/Chromium 浏览器，请安装 Google Chrome 或 Chromium",
		})
		return
	}

	log.Printf("[题库提取] 开始: %s", req.URL)

	// 启动浏览器
	l := launcher.New().
		Headless(true).
		NoSandbox(true).
		Set("disable-gpu").
		Set("disable-dev-shm-usage").
		Set("window-size", "1920,1080")

	if h.browserPath != "" {
		l.Bin(h.browserPath)
	}

	launcherURL, err := l.Launch()
	if err != nil {
		log.Printf("[题库提取] 启动浏览器失败: %v", err)
		c.JSON(http.StatusInternalServerError, gin.H{"error": "启动浏览器失败: " + err.Error()})
		return
	}

	browser := rod.New().ControlURL(launcherURL)
	if err := browser.Connect(); err != nil {
		log.Printf("[题库提取] 连接浏览器失败: %v", err)
		c.JSON(http.StatusInternalServerError, gin.H{"error": "连接浏览器失败: " + err.Error()})
		return
	}
	defer func() {
		time.Sleep(100 * time.Millisecond)
		browser.Close()
	}()

	page, err := browser.Page(proto.TargetCreateTarget{URL: "about:blank"})
	if err != nil {
		log.Printf("[题库提取] 创建页面失败: %v", err)
		c.JSON(http.StatusInternalServerError, gin.H{"error": "创建页面失败: " + err.Error()})
		return
	}

	// 第一步：导航到登录页面（从练习URL推导登录URL）
	loginURL := deriveLoginURL(req.URL)
	log.Printf("[题库提取] 导航到登录页: %s", loginURL)
	page.MustNavigate(loginURL)
	page.MustWaitLoad()

	// 第二步：自动登录
	if err := h.performLogin(page, req.Username, req.Password); err != nil {
		log.Printf("[题库提取] 登录失败: %v", err)
		c.JSON(http.StatusInternalServerError, gin.H{"error": "登录失败: " + err.Error()})
		return
	}

	// 第三步：导航到练习页面
	log.Printf("[题库提取] 导航到练习页: %s", req.URL)
	page.MustNavigate(req.URL)
	page.MustWaitLoad()
	time.Sleep(2 * time.Second)

	// 第四步：注入提取脚本
	if h.extractScript == "" {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "提取脚本未加载"})
		return
	}

	_, err = page.Eval(h.extractScript)
	if err != nil {
		log.Printf("[题库提取] 注入脚本失败: %v", err)
		c.JSON(http.StatusInternalServerError, gin.H{"error": "注入脚本失败: " + err.Error()})
		return
	}

	// 第五步：执行批量提取
	result, err := page.Eval(`() => window.__extractAllQuestions()`)
	if err != nil {
		log.Printf("[题库提取] 执行提取失败: %v", err)
		c.JSON(http.StatusInternalServerError, gin.H{"error": "提取失败: " + err.Error()})
		return
	}

	// 解析结果
	var questions []map[string]interface{}
	if err := json.Unmarshal([]byte(result.Value.Str()), &questions); err != nil {
		log.Printf("[题库提取] 解析结果失败: %v", err)
		c.JSON(http.StatusInternalServerError, gin.H{"error": "解析结果失败", "raw": result.Value.Str()})
		return
	}

	log.Printf("[题库提取] 完成: 提取了 %d 道题", len(questions))
	c.JSON(http.StatusOK, gin.H{
		"success":   true,
		"count":     len(questions),
		"questions": questions,
	})
}

// deriveLoginURL 从练习URL推导登录URL
func deriveLoginURL(practiceURL string) string {
	// 融智云考登录页:
	// https://www.cctrcloud.net -> https://www.cctrcloud.net/login
	// https://kwk.ahau.edu.cn -> https://kwk.ahau.edu.cn/login
	u := practiceURL
	// 去掉尾部路径
	for i := len(u) - 1; i >= 0; i-- {
		if u[i] == '/' {
			u = u[:i]
			break
		}
	}
	// 去掉最后一层路径
	for i := len(u) - 1; i >= 0; i-- {
		if u[i] == '/' {
			u = u[:i]
			break
		}
	}
	return u + "/login"
}

// performLogin 在页面上执行登录
func (h *ExamHandler) performLogin(page *rod.Page, username, password string) error {
	// 等待登录表单加载
	page.MustWaitLoad()
	time.Sleep(1 * time.Second)

	// 尝试填入用户名
	usernameSelectors := []string{
		"#username",
		"#userName",
		"#account",
		"#user_account",
		"input[name='username']",
		"input[name='userName']",
		"input[name='account']",
		"input[type='text']",
	}

	var usernameEl *rod.Element
	for _, sel := range usernameSelectors {
		el, err := page.Element(sel)
		if err == nil && el != nil {
			usernameEl = el
			break
		}
	}

	if usernameEl == nil {
		log.Println("[题库提取] 未找到用户名输入框，可能已登录")
		return nil
	}

	usernameEl.MustInput(username)

	// 填入密码
	passwordSelectors := []string{
		"#password",
		"#passWord",
		"#pwd",
		"input[name='password']",
		"input[name='passWord']",
		"input[type='password']",
	}

	var passwordEl *rod.Element
	for _, sel := range passwordSelectors {
		el, err := page.Element(sel)
		if err == nil && el != nil {
			passwordEl = el
			break
		}
	}

	if passwordEl != nil {
		passwordEl.MustInput(password)
	}

	// 点击登录按钮
	loginBtnSelectors := []string{
		"#loginBtn",
		"#login_btn",
		"button[type='submit']",
		"input[type='submit']",
		"button.login-btn",
		".login-btn",
		"button:has-text('登录')",
	}

	for _, sel := range loginBtnSelectors {
		el, err := page.Element(sel)
		if err == nil && el != nil {
			el.MustClick()
			break
		}
	}

	// 等待登录完成（页面跳转）
	page.MustWaitLoad()
	time.Sleep(2 * time.Second)

	// 检查是否成功登录（页面是否跳转）
	pageURL := page.MustInfo().URL
	log.Printf("[题库提取] 登录后页面: %s", pageURL)
	if pageURL == "about:blank" {
		// 用 JS 检查
		url, _ := page.Eval(`() => window.location.href`)
		log.Printf("[题库提取] 当前URL: %s", url.Value.String())
	}

	return nil
}
