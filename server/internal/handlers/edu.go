package handlers

import (
	"crypto/rand"
	"crypto/rsa"
	"encoding/base64"
	"encoding/json"
	"errors"
	"math/big"
	"net/http"
	"net/url"
	"regexp"
	"strconv"
	"strings"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/go-resty/resty/v2"
	"golang.org/x/crypto/bcrypt"
	"gorm.io/gorm"
	"xiaoyuan/internal/models"
)

const (
	indexUrl  = "https://jxw.sylu.edu.cn/xtgl"
	courseUrl = "https://jxw.sylu.edu.cn/kbcx"
	gradeUrl  = "https://jxw.sylu.edu.cn/cjcx"
)

var (
	Error302          = errors.New("post redirect disabled")
	ErrorLapse        = errors.New("cookie已失效")
	ErrorCourseNoOpen = errors.New("当前学期课表暂未开放")
	ErrorGradesNoOpen = errors.New("当前学期暂无成绩")
)

// PublicKey 公钥结构
type PublicKey struct {
	Modulus  string `json:"modulus"`
	Exponent string `json:"exponent"`
}

// EduHandler 教务处理器
type EduHandler struct {
	db *gorm.DB
}

// NewEduHandler 创建教务处理器
func NewEduHandler(db *gorm.DB) *EduHandler {
	return &EduHandler{db: db}
}

// baseHttpHeaders 请求头
func baseHttpHeaders() map[string]string {
	return map[string]string{
		"User-Agent":    "Mozilla/5.0 (Windows NT 6.1; WOW64; rv:29.0) Gecko/20100101 Firefox/29.0",
		"Content-Type":  "application/x-www-form-urlencoded;charset=uft-8",
		"Cache-Control": "no-cache",
	}
}

// nowTime 获取当前时间戳
func nowTime() string {
	return strconv.FormatInt(time.Now().UnixMilli(), 10)
}

// BindEduInput 绑定教务输入
type BindEduInput struct {
	StudentID string `json:"student_id" binding:"required,len=10"`
	Password  string `json:"password" binding:"required"`
}

// BindEdu 绑定教务账号
func (h *EduHandler) BindEdu(c *gin.Context) {
	userID, _ := c.Get("user_id")

	var input BindEduInput
	if err := c.ShouldBindJSON(&input); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
		return
	}

	// 创建 resty 客户端
	client := resty.New()

	// 获取csrf token
	csrfToken, err := getIndexCookieAndCsrfToken(client)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "获取登录令牌失败"})
		return
	}

	// 获取公钥
	publicKey, err := getPublicKey(client)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "获取公钥失败"})
		return
	}

	// RSA加密密码
	encryptedPassword, err := rsaByPublicKey(input.Password, publicKey)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "密码加密失败"})
		return
	}

	// 尝试登录
	cookies, err := syluLogin(client, input.StudentID, encryptedPassword, csrfToken)
	if err != nil {
		c.JSON(http.StatusUnauthorized, gin.H{"error": "教务账号或密码错误"})
		return
	}

	// 构建cookie字符串
	cookieStr := buildCookieString(cookies)

	// 加密存储教务密码
	hashedPassword, _ := bcrypt.GenerateFromPassword([]byte(input.Password), bcrypt.DefaultCost)

	// 更新用户教务信息
	h.db.Model(&models.User{}).Where("id = ?", userID).Updates(map[string]interface{}{
		"edu_student_id": input.StudentID,
		"edu_password":   string(hashedPassword),
		"edu_cookie":     cookieStr,
		"edu_bound":      true,
	})

	c.JSON(http.StatusOK, gin.H{
		"message":     "绑定成功",
		"edu_student_id": input.StudentID,
	})
}

// UnbindEdu 解绑教务账号
func (h *EduHandler) UnbindEdu(c *gin.Context) {
	userID, _ := c.Get("user_id")

	h.db.Model(&models.User{}).Where("id = ?", userID).Updates(map[string]interface{}{
		"edu_student_id": "",
		"edu_password":   "",
		"edu_cookie":     "",
		"edu_bound":      false,
		"edu_grade":      "",
		"edu_college":    "",
		"edu_major":      "",
	})

	c.JSON(http.StatusOK, gin.H{"message": "解绑成功"})
}

// GetEduStatus 获取教务绑定状态
func (h *EduHandler) GetEduStatus(c *gin.Context) {
	userID, _ := c.Get("user_id")

	var user models.User
	if err := h.db.First(&user, userID).Error; err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "用户不存在"})
		return
	}

	c.JSON(http.StatusOK, gin.H{
		"edu_bound":     user.EduBound,
		"edu_student_id": user.EduStudentID,
		"edu_grade":     user.EduGrade,
		"edu_college":   user.EduCollege,
		"edu_major":     user.EduMajor,
	})
}

// CourseInput 课表查询输入
type CourseInput struct {
	Year     string `json:"year" binding:"required"`
	Semester int    `json:"semester" binding:"required,oneof=3 12"`
}

// GetCourses 获取课表
func (h *EduHandler) GetCourses(c *gin.Context) {
	userID, _ := c.Get("user_id")

	// 获取用户的教务Cookie
	var user models.User
	if err := h.db.First(&user, userID).Error; err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "用户不存在"})
		return
	}

	if !user.EduBound || user.EduCookie == "" {
		c.JSON(http.StatusBadRequest, gin.H{"error": "请先绑定教务账号"})
		return
	}

	var input CourseInput
	if err := c.ShouldBindJSON(&input); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
		return
	}

	client := resty.New()
	courses, err := getCourseByInfo(client, user.EduCookie, input.Year, input.Semester)
	if err != nil {
		if errors.Is(err, ErrorLapse) {
			c.JSON(http.StatusUnauthorized, gin.H{"error": "教务Cookie已失效，请重新绑定"})
			return
		}
		if errors.Is(err, ErrorCourseNoOpen) {
			c.JSON(http.StatusOK, gin.H{"error": "当前学期课表暂未开放"})
			return
		}
		c.JSON(http.StatusInternalServerError, gin.H{"error": err.Error()})
		return
	}

	c.JSON(http.StatusOK, courses)
}

// GradesInput 成绩查询输入
type GradesInput struct {
	Year     string `json:"year" binding:"required"`
	Semester int    `json:"semester" binding:"required,oneof=3 12"`
}

// GetGrades 获取成绩
func (h *EduHandler) GetGrades(c *gin.Context) {
	userID, _ := c.Get("user_id")

	var user models.User
	if err := h.db.First(&user, userID).Error; err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "用户不存在"})
		return
	}

	if !user.EduBound || user.EduCookie == "" {
		c.JSON(http.StatusBadRequest, gin.H{"error": "请先绑定教务账号"})
		return
	}

	var input GradesInput
	if err := c.ShouldBindJSON(&input); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
		return
	}

	client := resty.New()
	grades, err := getGradesByInfo(client, user.EduCookie, input.Year, input.Semester)
	if err != nil {
		if errors.Is(err, ErrorLapse) {
			c.JSON(http.StatusUnauthorized, gin.H{"error": "教务Cookie已失效，请重新绑定"})
			return
		}
		if errors.Is(err, ErrorGradesNoOpen) {
			c.JSON(http.StatusOK, gin.H{"grades": []interface{}{}, "message": "当前学期暂无成绩"})
			return
		}
		c.JSON(http.StatusInternalServerError, gin.H{"error": err.Error()})
		return
	}

	c.JSON(http.StatusOK, gin.H{"grades": grades})
}

// 以下是整合的教务系统登录和查询逻辑

func getIndexCookieAndCsrfToken(client *resty.Client) (string, error) {
	client.SetTimeout(3 * time.Second)

initResp, err := client.R().SetHeaders(baseHttpHeaders()).Get(indexUrl + "/login_slogin.html")
	if err != nil {
		if urlErr, ok := err.(*url.Error); ok && urlErr.Timeout() {
			return getIndexCookieAndCsrfToken(client)
		}
		return "", err
	}

	findCsrfToken := regexp.MustCompile(`id="csrftoken" name="csrftoken" value="([^"]+)"`)
	matches := findCsrfToken.FindStringSubmatch(string(initResp.Body()))
	if len(matches) < 2 {
		return "", errors.New("无法获取csrf token")
	}

	client.Cookies = initResp.Cookies()
	return matches[1], nil
}

func getPublicKey(client *resty.Client) (*PublicKey, error) {
	resp, err := client.R().SetHeaders(baseHttpHeaders()).
		SetQueryParams(map[string]string{
			"time": nowTime(),
			"_":    nowTime(),
		}).Get(indexUrl + "/login_getPublicKey.html")

	if err != nil {
		return nil, err
	}

	var publicKey PublicKey
	if err := json.Unmarshal(resp.Body(), &publicKey); err != nil {
		return nil, err
	}
	return &publicKey, nil
}

func rsaByPublicKey(password string, publicKey *PublicKey) (string, error) {
	modulusBytes, err := base64.StdEncoding.DecodeString(publicKey.Modulus)
	if err != nil {
		return "", err
	}

	exponentBytes, err := base64.StdEncoding.DecodeString(publicKey.Exponent)
	if err != nil {
		return "", err
	}

	pubKey := &rsa.PublicKey{
		N: new(big.Int).SetBytes(modulusBytes),
		E: int(new(big.Int).SetBytes(exponentBytes).Int64()),
	}

	encryptedBytes, err := rsa.EncryptPKCS1v15(rand.Reader, pubKey, []byte(password))
	if err != nil {
		return "", err
	}

	return base64.StdEncoding.EncodeToString(encryptedBytes), nil
}

func syluLogin(client *resty.Client, studentID, encryptedPassword, csrfToken string) ([]*http.Cookie, error) {
	resp, err := client.SetRedirectPolicy(resty.NoRedirectPolicy()).R().
		SetFormData(map[string]string{
			"csrftoken": csrfToken,
			"language":  "zh_CN",
			"yhm":       studentID,
			"mm":        encryptedPassword,
		}).
		SetQueryParam("time", nowTime()).
		SetHeaders(baseHttpHeaders()).
		Post(indexUrl + "/login_slogin.html")

	if err != nil && err.Error() != Error302.Error() {
		return nil, errors.New("服务器连接失败:" + err.Error())
	}

	return resp.Cookies(), nil
}

func buildCookieString(cookies []*http.Cookie) string {
	var parts []string
	for _, c := range cookies {
		parts = append(parts, c.Name+"="+c.Value)
	}
	return strings.Join(parts, "; ")
}

// 课程相关结构
type scheduleResponse struct {
	RqazcList []struct {
		Rq string `json:"rq"`
	} `json:"rqazcList"`
	KbList []struct {
		Name     string `json:"NAME"`
		Teacher  string `json:"JSMC"`
		Location string `json:"XQSM"`
		Time     string `json:"SJBJ"`
		WeekDay  string `json:"XQ"`
		WeekS    string `json:"ZCD"`
	} `json:"kbList"`
}

type courseResponse struct {
	Courses []courseInfo `json:"courses"`
}

type courseInfo struct {
	Name     string `json:"name"`
	Teacher  string `json:"teacher"`
	Location string `json:"location"`
	Time     int    `json:"time"`
	WeekDay  int    `json:"week_day"`
	WeekS    []int  `json:"weeks"`
}

func getCourseByInfo(client *resty.Client, cookie, year string, semester int) (*courseResponse, error) {
	client.SetHostURL(courseUrl)
	defer client.GetClient().CloseIdleConnections()

	formData := map[string]string{
		"xnm":    year,
		"zs":     "1",
		"doType": " app",
		"xqm":    strconv.Itoa(semester),
		"kblx":   "1",
	}

	resp, err := client.R().
		SetFormData(formData).
		SetHeader("Cookie", cookie).
		Post("/xskbcxMobile_cxXsKb.html?gnmkdm=N2154")

	if err != nil {
		return nil, err
	}

	if string(resp.Body()) == "null" {
		return nil, ErrorLapse
	}

	var schedule scheduleResponse
	if err := json.Unmarshal(resp.Body(), &schedule); err != nil {
		return nil, err
	}

	if len(schedule.KbList) == 0 {
		return nil, ErrorCourseNoOpen
	}

	result := &courseResponse{Courses: make([]courseInfo, 0, len(schedule.KbList))}

	for _, v := range schedule.KbList {
		course := courseInfo{
			Name:     v.Name,
			Teacher:  v.Teacher,
			Location: v.Location,
			Time:     timeToInt(v.Time),
			WeekDay:  parseWeekday(v.WeekDay),
			WeekS:    parseWeeks(v.WeekS),
		}
		result.Courses = append(result.Courses, course)
	}

	return result, nil
}

// 成绩相关结构
type gradesResponse struct {
	Items []struct {
		Kcmc   string `json:"KCMC"` // 课程名称
		JxbID  string `json:"JXBID"` // 教学班ID
		Jsxm   string `json:"JSXM"` // 教师姓名
		Sfxwkc string `json:"SFXWKC"` // 是否学位课
		Xf     string `json:"XF"` // 学分
		Jd     string `json:"JD"` // 绩点
		Xfjd   string `json:"XFJD"` // 学分绩点
		Bfzcj  string `json:"BFZCJ"` // 百分成绩
		Cj     string `json:"CJ"` // 成绩
	} `json:"items"`
}

type gradeInfo struct {
	Name       string  `json:"name"`
	ClassID    string  `json:"class_id"`
	Teacher    string  `json:"teacher"`
	IsDegree   bool    `json:"is_degree"`
	Credits    float64 `json:"credits"`
	GPA        float64 `json:"gpa"`
	GradePoints float64 `json:"grade_points"`
	Fraction   float64 `json:"fraction"`
	Grade      string  `json:"grade"`
}

func getGradesByInfo(client *resty.Client, cookie, year string, semester int) ([]gradeInfo, error) {
	client.SetHostURL(gradeUrl)
	defer client.GetClient().CloseIdleConnections()

	queryData := map[string]string{
		"doType": "query",
		"gnmkdm": "N305005",
	}

	formData := map[string]string{
		"xnm":                  year,
		"xqm":                  strconv.Itoa(semester),
		"queryModel.showCount": "30",
	}

	resp, err := client.R().
		SetQueryParams(queryData).
		SetFormData(formData).
		SetHeader("Cookie", cookie).
		Post("/cjcx_cxXsgrcj.html")

	if err != nil {
		return nil, err
	}

	if strings.Contains(string(resp.Header().Get("Content-Type")), "text/html") {
		return nil, ErrorLapse
	}

	var grades gradesResponse
	if err := json.Unmarshal(resp.Body(), &grades); err != nil {
		return nil, err
	}

	if len(grades.Items) < 1 {
		return nil, ErrorGradesNoOpen
	}

	result := make([]gradeInfo, 0, len(grades.Items))
	for _, v := range grades.Items {
		grade := gradeInfo{
			Name:     v.Kcmc,
			ClassID:  v.JxbID,
			Teacher:  v.Jsxm,
			IsDegree: v.Sfxwkc == "是",
		}
		grade.Credits, _ = strconv.ParseFloat(v.Xf, 64)
		grade.GPA, _ = strconv.ParseFloat(v.Jd, 64)
		grade.GradePoints, _ = strconv.ParseFloat(v.Xfjd, 64)
		grade.Fraction, _ = strconv.ParseFloat(v.Bfzcj, 64)
		grade.Grade = v.Cj
		result = append(result, grade)
	}

	return result, nil
}

func parseWeekday(s string) int {
	if v, err := strconv.Atoi(s); err == nil {
		return v
	}
	return 0
}

func parseWeeks(input string) []int {
	var weeks []int
	ranges := strings.Split(input, ",")
	for _, r := range ranges {
		re := regexp.MustCompile(`(\d+)`)
		bounds := re.FindAllString(r, -1)
		if len(bounds) > 1 {
			start, _ := strconv.Atoi(bounds[0])
			end, _ := strconv.Atoi(bounds[1])
			for i := start; i <= end; i++ {
				weeks = append(weeks, i)
			}
		} else if len(bounds) == 1 {
			start, _ := strconv.Atoi(bounds[0])
			weeks = append(weeks, start)
		}
	}
	return weeks
}

func timeToInt(time string) int {
	switch time {
	case "1-2节":
		return 1
	case "3-4节":
		return 2
	case "5-6节":
		return 3
	case "7-8节":
		return 4
	case "9-10节":
		return 5
	case "11-12节":
		return 6
	case "13-14节":
		return 7
	}
	return 0
}