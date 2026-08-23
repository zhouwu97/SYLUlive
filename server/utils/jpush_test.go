package utils

import (
	"encoding/json"
	"strings"
	"testing"
)

func TestJPushAliasPayloadIncludesAndroidAndIOSChannels(t *testing.T) {
	payload := PushPayload{
		Platform: "all",
		Audience: Audience{Alias: []string{"42"}},
		Notification: Notification{
			Alert:   "测试消息",
			Android: &AndroidNotification{Alert: "测试消息", Title: "系统通知"},
			IOS:     &IOSNotification{Alert: "测试消息", Sound: "default", Badge: 1},
		},
	}

	encoded, err := json.Marshal(payload)
	if err != nil {
		t.Fatalf("marshal payload: %v", err)
	}
	body := string(encoded)
	for _, fragment := range []string{`"platform":"all"`, `"android"`, `"ios"`, `"badge":1`} {
		if !strings.Contains(body, fragment) {
			t.Fatalf("payload missing %q: %s", fragment, body)
		}
	}
}

func TestJPushIOSRegistrationPayloadOmitsAndroidChannel(t *testing.T) {
	payload := PushPayload{
		Platform: "ios",
		Audience: Audience{RegistrationID: []string{"ios-rid"}},
		Notification: Notification{
			Alert: "回复",
			IOS:   &IOSNotification{Alert: "回复", Sound: "default", Badge: 1},
		},
	}

	encoded, err := json.Marshal(payload)
	if err != nil {
		t.Fatalf("marshal payload: %v", err)
	}
	body := string(encoded)
	if strings.Contains(body, `"android"`) {
		t.Fatalf("iOS payload unexpectedly contains Android channel: %s", body)
	}
}
