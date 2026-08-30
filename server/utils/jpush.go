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

// JPushClient 极光推送客户端。
type JPushClient struct {
	AppKey       string
	MasterSecret string
}

// PushPayload 极光 V3 接口 JSON 结构体。
type PushPayload struct {
	Platform     string       `json:"platform"`
	Audience     Audience     `json:"audience"`
	Notification Notification `json:"notification"`
}

// Audience 推送目标。
type Audience struct {
	RegistrationID []string `json:"registration_id,omitempty"`
	Alias          []string `json:"alias,omitempty"`
}

// Notification 同时承载 Android 与 APNs 通知内容。
type Notification struct {
	Alert   string               `json:"alert"`
	Android *AndroidNotification `json:"android,omitempty"`
	IOS     *IOSNotification     `json:"ios,omitempty"`
}

// AndroidNotification Android 平台通知。
type AndroidNotification struct {
	Alert     string                 `json:"alert"`
	Title     string                 `json:"title"`
	Extras    map[string]interface{} `json:"extras,omitempty"`
	ChannelID string                 `json:"channel_id,omitempty"`
	LargeIcon string                 `json:"large_icon,omitempty"`
}

// IOSNotification APNs 通知内容。字段名遵循 JPush iOS notification schema。
type IOSNotification struct {
	Alert            string                 `json:"alert"`
	Sound            string                 `json:"sound,omitempty"`
	Badge            interface{}            `json:"badge,omitempty"`
	ContentAvailable bool                   `json:"content-available,omitempty"`
	MutableContent   bool                   `json:"mutable-content,omitempty"`
	Extras           map[string]interface{} `json:"extras,omitempty"`
}

// NewJPushClient 初始化极光客户端。
func NewJPushClient(appKey, masterSecret string) *JPushClient {
	return &JPushClient{AppKey: appKey, MasterSecret: masterSecret}
}

// SendNotification 保留旧 API，默认发送 Android 设备通知。
func (c *JPushClient) SendNotification(rid, title, alert string, extras map[string]interface{}) error {
	return c.SendRegistrationNotification(rid, "android", title, alert, extras)
}

// SendRegistrationNotification 按设备平台向指定 RegistrationID 推送。
func (c *JPushClient) SendRegistrationNotification(rid, platform, title, alert string, extras map[string]interface{}) error {
	var largeIcon string
	if avatar, ok := extras["sender_avatar"].(string); ok && avatar != "" {
		largeIcon = avatar
	}

	android := &AndroidNotification{
		Alert: alert, Title: title, Extras: extras, LargeIcon: largeIcon,
	}
	ios := &IOSNotification{Alert: alert, Sound: "default", Badge: 1, Extras: extras}

	switch platform {
	case "ios":
		android = nil
	case "android":
		ios = nil
	default:
		platform = "all"
	}

	return c.send(PushPayload{
		Platform:     platform,
		Audience:     Audience{RegistrationID: []string{rid}},
		Notification: Notification{Alert: alert, Android: android, IOS: ios},
	})
}

// SendAliasNotification 按用户 alias 推送到该用户已绑定的所有 JPush 平台。
func (c *JPushClient) SendAliasNotification(alias, title, alert string, extras map[string]interface{}) error {
	var largeIcon string
	if avatar, ok := extras["sender_avatar"].(string); ok && avatar != "" {
		largeIcon = avatar
	}
	return c.send(PushPayload{
		Platform: "all",
		Audience: Audience{Alias: []string{alias}},
		Notification: Notification{
			Alert: alert,
			Android: &AndroidNotification{
				Alert: alert, Title: title, Extras: extras,
				ChannelID: "private_messages", LargeIcon: largeIcon,
			},
			IOS: &IOSNotification{
				Alert: alert, Sound: "default", Badge: 1, Extras: extras,
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
