package models

import (
	"encoding/json"
	"strings"
	"testing"
)

func TestReplyTargetMarshalExposesOnlyPublicNickname(t *testing.T) {
	target := User{
		ID: 2, Nickname: "公开回复对象", Role: RoleSuperAdmin,
		StudentID: "private-target-student", EduStudentID: "private-target-edu-student",
		Email: "private-target-email@example.test", PasswordHash: "private-target-password-hash",
		EduPassword: "private-target-school-password", EduCookie: "private-target-school-cookie",
		DeviceToken: "private-target-device-token", PushInstallationID: "private-target-installation",
		QQ: "private-target-qq", EduCollege: "private-target-college", EduMajor: "private-target-major",
		Avatar: "/private-target-avatar.png", Background: "/private-target-background.png",
		EduAuthorized: true, EduBound: true,
	}
	parentID := uint(9)
	reply := Reply{
		ID: 11, PostID: 10, ParentReplyID: &parentID, ReplyToUserID: &target.ID,
		AuthorID: 1, Author: User{ID: 1, Nickname: "公开回复作者"},
		Content: "普通正文", ReplyToUser: &target,
	}
	body, err := json.Marshal(reply)
	if err != nil {
		t.Fatal(err)
	}
	var payload map[string]interface{}
	if err := json.Unmarshal(body, &payload); err != nil {
		t.Fatal(err)
	}
	if payload["reply_to_name"] != target.Nickname || payload["reply_to_user_id"] != float64(target.ID) {
		t.Fatalf("精确回复对象的公开标识丢失: %s", body)
	}
	for _, field := range []string{
		"ReplyToUser", "reply_to_user", "student_id", "edu_student_id", "email", "password_hash",
		"edu_password", "edu_cookie", "device_token", "push_installation_id", "qq", "role",
		"edu_authorized", "edu_bound", "edu_college", "edu_major",
	} {
		if _, exists := payload[field]; exists {
			t.Fatalf("回复对象内部字段 %s 被公开: %s", field, body)
		}
	}
	if strings.Contains(string(body), "private-target-") {
		t.Fatalf("回复对象除昵称之外的数据不应通过任何嵌套字段泄露: %s", body)
	}

	// 老记录或已删除账号没有可预载对象时，新增昵称字段应省略，仍保留旧字段。
	reply.ReplyToUser = nil
	body, err = json.Marshal(reply)
	if err != nil {
		t.Fatal(err)
	}
	payload = nil
	if err := json.Unmarshal(body, &payload); err != nil {
		t.Fatal(err)
	}
	if _, exists := payload["reply_to_name"]; exists {
		t.Fatalf("未知昵称不能伪造回复对象: %s", body)
	}
	if payload["reply_to_user_id"] != float64(target.ID) || payload["content"] != reply.Content {
		t.Fatalf("旧回复字段不应受新增昵称影响: %s", body)
	}
}
