package utils

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"time"
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
	RegistrationID []string `json:"registration_id,omitempty"`
	Alias          []string `json:"alias,omitempty"`
}

// Notification 通知内容
type Notification struct {
	Alert   string              `json:"alert"`
	Android AndroidNotification `json:"android,omitempty"`
}

// AndroidNotification Android 平台通知
type AndroidNotification struct {
	Alert     string                 `json:"alert"`
	Title     string                 `json:"title"`
	Extras    map[string]interface{} `json:"extras,omitempty"`
	ChannelID string                 `json:"channel_id,omitempty"`
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
	return c.send(PushPayload{
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
	})
}

// SendAliasNotification pushes a notification to the given JPush alias.
func (c *JPushClient) SendAliasNotification(alias, title, alert string, extras map[string]interface{}) error {
	return c.send(PushPayload{
		Platform: "android",
		Audience: Audience{
			Alias: []string{alias},
		},
		Notification: Notification{
			Alert: alert,
			Android: AndroidNotification{
				Alert:     alert,
				Title:     title,
				Extras:    extras,
				ChannelID: "private_messages",
			},
		},
	})
}

func (c *JPushClient) send(payload PushPayload) error {
	url := "https://api.jpush.cn/v3/push"

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

	client := &http.Client{Timeout: 5 * time.Second}
	resp, err := client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()

	body, _ := io.ReadAll(resp.Body)

	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("jpush error: http=%d body=%s", resp.StatusCode, string(body))
	}

	log.Printf("[JPUSH_OK] response=%s", string(body))
	return nil
}
