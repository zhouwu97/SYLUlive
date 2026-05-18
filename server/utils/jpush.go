package utils

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"net/http"
)

// JPushClient 极光推送客户端
type JPushClient struct {
	AppKey       string
	MasterSecret string
}

// PushPayload 极光 V3 接口 JSON 结构体
type PushPayload struct {
	Platform     string       `json:"platform"`
	Audience     Audience     `json:"audience"`
	Notification Notification `json:"notification"`
}

// Audience 推送目标
type Audience struct {
	RegistrationID []string `json:"registration_id"`
}

// Notification 通知内容
type Notification struct {
	Alert   string             `json:"alert"`
	Android AndroidNotification `json:"android,omitempty"`
}

// AndroidNotification Android 平台通知
type AndroidNotification struct {
	Alert  string                 `json:"alert"`
	Title  string                 `json:"title"`
	Extras map[string]interface{} `json:"extras,omitempty"`
}

// NewJPushClient 初始化极光客户端
func NewJPushClient(appKey, masterSecret string) *JPushClient {
	return &JPushClient{
		AppKey:       appKey,
		MasterSecret: masterSecret,
	}
}

// SendNotification 推送通知给指定设备
func (c *JPushClient) SendNotification(rid, title, alert string, extras map[string]interface{}) error {
	url := "https://api.jpush.cn/v3/push"

	payload := PushPayload{
		Platform: "android",
		Audience: Audience{
			RegistrationID: []string{rid},
		},
		Notification: Notification{
			Alert: alert,
			Android: AndroidNotification{
				Alert:  alert,
				Title:  title,
				Extras: extras,
			},
		},
	}

	jsonData, err := json.Marshal(payload)
	if err != nil {
		return err
	}

	req, err := http.NewRequest("POST", url, bytes.NewBuffer(jsonData))
	if err != nil {
		return err
	}

	req.Header.Set("Content-Type", "application/json")

	// Basic Auth 认证：base64(AppKey:MasterSecret)
	authStr := fmt.Sprintf("%s:%s", c.AppKey, c.MasterSecret)
	encodedAuth := base64.StdEncoding.EncodeToString([]byte(authStr))
	req.Header.Set("Authorization", "Basic "+encodedAuth)

	client := &http.Client{}
	resp, err := client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("jpush error: http %d", resp.StatusCode)
	}

	return nil
}