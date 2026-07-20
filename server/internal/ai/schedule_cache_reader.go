package ai

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strconv"
	"strings"
)

const maxScheduleCacheResponse = 2 << 20

// CachedCourse 与 python-edu-service 的 LocalCourse 响应保持只读契约一致。
type CachedCourse struct {
	ID            int    `json:"id"`
	CourseCode    string `json:"course_code"`
	CustomName    string `json:"custom_name"`
	OriginalName  string `json:"original_name"`
	Teacher       string `json:"teacher"`
	Location      string `json:"location"`
	Weekday       int    `json:"weekday"`
	StartSection  int    `json:"start_section"`
	EndSection    int    `json:"end_section"`
	Weeks         []int  `json:"weeks"`
	Year          string `json:"year"`
	Semester      int    `json:"semester"`
	ClassDuration int    `json:"class_duration"`
	BreakDuration int    `json:"break_duration"`
}

type scheduleCacheResponse struct {
	Courses []CachedCourse `json:"courses"`
}

// PythonScheduleCacheReader 只读取既有缓存，不触发登录、刷新或教务抓取。
type PythonScheduleCacheReader struct {
	baseURL      string
	serviceToken string
	httpClient   *http.Client
}

func NewPythonScheduleCacheReader(baseURL, serviceToken string, client *http.Client) (*PythonScheduleCacheReader, error) {
	parsed, err := url.Parse(strings.TrimRight(strings.TrimSpace(baseURL), "/"))
	if err != nil || (parsed.Scheme != "http" && parsed.Scheme != "https") || parsed.Host == "" {
		return nil, fmt.Errorf("invalid python edu service URL")
	}
	if strings.TrimSpace(serviceToken) == "" {
		return nil, fmt.Errorf("python edu service token is required")
	}
	if client == nil {
		client = http.DefaultClient
	}
	return &PythonScheduleCacheReader{
		baseURL:      parsed.String(),
		serviceToken: serviceToken,
		httpClient:   client,
	}, nil
}

// Read 按服务端根据已核验 v2 校历解析出的学年和学期代码读取缓存。
func (r *PythonScheduleCacheReader) Read(ctx context.Context, userID uint, academicYear string, semesterCode int) ([]CachedCourse, error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	if userID == 0 || !academicYearPattern.MatchString(academicYear) {
		return nil, fmt.Errorf("invalid schedule cache identity or academic year")
	}
	if semesterCode != 3 && semesterCode != 12 {
		return nil, fmt.Errorf("semester code must be 3 or 12")
	}
	endpoint, _ := url.Parse(r.baseURL + "/api/edu/courses/local")
	query := endpoint.Query()
	query.Set("year", academicYear[:4])
	query.Set("semester", strconv.Itoa(semesterCode))
	endpoint.RawQuery = query.Encode()

	request, err := http.NewRequestWithContext(ctx, http.MethodGet, endpoint.String(), nil)
	if err != nil {
		return nil, err
	}
	request.Header.Set("X-Internal-Service-Token", r.serviceToken)
	request.Header.Set("X-Internal-User-ID", strconv.FormatUint(uint64(userID), 10))
	response, err := r.httpClient.Do(request)
	if err != nil {
		return nil, err
	}
	defer response.Body.Close()
	body, err := io.ReadAll(io.LimitReader(response.Body, maxScheduleCacheResponse+1))
	if err != nil {
		return nil, err
	}
	if len(body) > maxScheduleCacheResponse {
		return nil, fmt.Errorf("schedule cache response exceeds limit")
	}
	if response.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("schedule cache returned HTTP %d", response.StatusCode)
	}
	var payload scheduleCacheResponse
	if err := json.Unmarshal(body, &payload); err != nil {
		return nil, fmt.Errorf("decode schedule cache: %w", err)
	}
	for index, course := range payload.Courses {
		if course.Weekday < 1 || course.Weekday > 7 || course.StartSection < 1 || course.EndSection < course.StartSection || course.Semester != semesterCode {
			return nil, fmt.Errorf("invalid schedule cache course at index %d", index)
		}
	}
	return payload.Courses, nil
}

var academicYearPattern = mustCompileAcademicYear()

func mustCompileAcademicYear() interface{ MatchString(string) bool } {
	return academicYearMatcher{}
}

type academicYearMatcher struct{}

func (academicYearMatcher) MatchString(value string) bool {
	if len(value) != 9 || value[4] != '-' {
		return false
	}
	first, err1 := strconv.Atoi(value[:4])
	second, err2 := strconv.Atoi(value[5:])
	return err1 == nil && err2 == nil && second == first+1
}
