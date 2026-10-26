package utils

import (
	"encoding/json"
	"io"
	"net/http"
	"strings"
	"testing"
)

type replyPushTestTransport func(*http.Request) (*http.Response, error)

func (f replyPushTestTransport) RoundTrip(r *http.Request) (*http.Response, error) {
	return f(r)
}

func TestReplyPushUsesHighImportanceChannelOnlyOnAndroid(t *testing.T) {
	original := http.DefaultTransport
	t.Cleanup(func() { http.DefaultTransport = original })
	for _, tc := range []struct {
		platform, kind, channel string
	}{
		{"android", "reply", "reply_notifications_v1"},
		{"android", "private_message", ""},
		{"ios", "reply", ""},
	} {
		t.Run(tc.platform+"_"+tc.kind, func(t *testing.T) {
			http.DefaultTransport = replyPushTestTransport(func(r *http.Request) (*http.Response, error) {
				var payload PushPayload
				if err := json.NewDecoder(r.Body).Decode(&payload); err != nil {
					t.Fatal(err)
				}
				if tc.platform == "ios" {
					if payload.Notification.Android != nil || payload.Notification.IOS.Sound != "default" {
						t.Fatal("iOS payload changed")
					}
				} else if payload.Notification.Android == nil || payload.Notification.Android.ChannelID != tc.channel {
					t.Fatalf("expected channel %q: %+v", tc.channel, payload.Notification.Android)
				}
				return &http.Response{StatusCode: http.StatusOK, Body: io.NopCloser(strings.NewReader(`{"msg_id":"test"}`))}, nil
			})
			if err := NewJPushClient("test", "test").SendRegistrationNotification("test-rid", tc.platform, "测试", "虚构内容", map[string]interface{}{"type": tc.kind}); err != nil {
				t.Fatal(err)
			}
		})
	}
}

func TestJPushRegistrationPayloadIncludesAndroidAndIOSChannels(t *testing.T) {
	payload := PushPayload{
		Platform: "all",
		Audience: Audience{RegistrationID: []string{"rid-42"}},
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
	for _, fragment := range []string{`"platform":"all"`, `"registration_id":["rid-42"]`, `"android"`, `"ios"`, `"badge":1`} {
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
