package models

import (
	"strings"
	"testing"
)

// 申诉结案通知的核心契约：
//  1. 一次结案只给申诉人一条通知（此前 appeal_result 与 appeal_approved 并列发送）；
//  2. 帖子类申诉必须挂在 PostID 上，客户端才能直达帖子治理结果区；
//  3. 回复类申诉的 PostID 只是所属帖子，不能改挂 PostID 并宣称“帖子已恢复展示”；
//  4. 未决/转人工等未结案状态维持原有公众法庭通知。
func TestResolveAppealAppellantNotification(t *testing.T) {
	tests := []struct {
		name               string
		appeal             Appeal
		closedByReview     bool
		wantType           string
		wantDedup          string
		wantPostScoped     bool
		wantContentKeyword string
	}{
		{
			name:               "帖子申诉通过：挂 PostID，指向帖子治理结果",
			appeal:             Appeal{ID: 7, TargetType: "post", PostID: 42, Status: AppealStatusPass},
			wantType:           NotificationTypeAppealApproved,
			wantDedup:          "appeal-approved:7",
			wantPostScoped:     true,
			wantContentKeyword: "恢复",
		},
		{
			name:               "帖子申诉驳回：挂 PostID，提示仍可继续整改",
			appeal:             Appeal{ID: 8, TargetType: "post", PostID: 42, Status: AppealStatusReject},
			wantType:           NotificationTypeAppealRejected,
			wantDedup:          "appeal-rejected:8",
			wantPostScoped:     true,
			wantContentKeyword: "维持不变",
		},
		{
			name:               "回复申诉通过：不能宣称帖子已恢复，回落公众法庭",
			appeal:             Appeal{ID: 9, TargetType: "reply", PostID: 42, Status: AppealStatusPass},
			wantType:           NotificationTypeAppealResult,
			wantDedup:          "appeal-result:9:appellant",
			wantPostScoped:     false,
			wantContentKeyword: "结案",
		},
		{
			name:               "人工复核结案：非帖子目标使用复核文案",
			appeal:             Appeal{ID: 10, TargetType: "teacher_rating", PostID: 0, Status: AppealStatusReject},
			closedByReview:     true,
			wantType:           NotificationTypeAppealResult,
			wantDedup:          "appeal-result:10:appellant",
			wantPostScoped:     false,
			wantContentKeyword: "人工复核",
		},
		{
			name:               "转人工复核：待办而非结果",
			appeal:             Appeal{ID: 11, TargetType: "post", PostID: 42, Status: AppealStatusReview},
			wantType:           NotificationTypeAppealReviewRequired,
			wantDedup:          "appeal-review-required:11:appellant",
			wantPostScoped:     false,
			wantContentKeyword: "独立管理员复核",
		},
		{
			name:               "帖子 ID 缺失时回落公众法庭，避免通知挂到 0 号帖子",
			appeal:             Appeal{ID: 12, TargetType: "post", PostID: 0, Status: AppealStatusPass},
			wantType:           NotificationTypeAppealResult,
			wantDedup:          "appeal-result:12:appellant",
			wantPostScoped:     false,
			wantContentKeyword: "结案",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := ResolveAppealAppellantNotification(tt.appeal, tt.closedByReview)
			if got.Type != tt.wantType {
				t.Errorf("Type = %q, want %q", got.Type, tt.wantType)
			}
			if got.DedupKey != tt.wantDedup {
				t.Errorf("DedupKey = %q, want %q", got.DedupKey, tt.wantDedup)
			}
			if got.PostScoped != tt.wantPostScoped {
				t.Errorf("PostScoped = %v, want %v", got.PostScoped, tt.wantPostScoped)
			}
			if tt.wantContentKeyword != "" &&
				!strings.Contains(got.Content, tt.wantContentKeyword) {
				t.Errorf("Content = %q, want 包含 %q", got.Content, tt.wantContentKeyword)
			}
		})
	}
}

// 帖子类申诉结案后不得再产出 appeal_result 命名空间的通知 —— 那正是修复前与
// appeal_approved 并列发送、让作者连收两条的重复项。
func TestPostAppealClosureNeverEmitsDuplicateAppealResult(t *testing.T) {
	for _, status := range []AppealStatus{AppealStatusPass, AppealStatusReject} {
		appeal := Appeal{ID: 3, TargetType: "post", PostID: 5, Status: status}
		got := ResolveAppealAppellantNotification(appeal, false)
		if got.DedupKey == "appeal-result:3:appellant" {
			t.Fatalf("status=%s 仍产出重复的 appeal_result 通知", status)
		}
		if !got.PostScoped {
			t.Fatalf("status=%s 帖子申诉通知未挂 PostID，客户端无法直达帖子", status)
		}
	}
}

// 同一条申诉重复结案（事务重试、定时任务重跑）必须得到完全相同的通知键，
// 否则唯一索引失效、作者会被重复提醒。
func TestResolveAppealAppellantNotificationIsIdempotent(t *testing.T) {
	appeal := Appeal{ID: 21, TargetType: "post", PostID: 33, Status: AppealStatusReject}
	first := ResolveAppealAppellantNotification(appeal, false)
	second := ResolveAppealAppellantNotification(appeal, false)
	if first != second {
		t.Fatalf("同一申诉两次推导结果不一致: %+v vs %+v", first, second)
	}
}
