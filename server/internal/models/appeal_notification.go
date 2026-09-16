package models

import "fmt"

// AppealAppellantNotification 是一次申诉结案应发给申诉人的「主通知」。
//
// 抽到 models 层是因为两条结案路径必须得出完全相同的结论：即时结案
// （handlers/appeal.go 投票达到可裁决状态）与到期兜底结案
// （tasks/appeal_finalizer.go 定时任务）。同一个结案事件不能因为走的是哪条路径，
// 就让作者收到不同数量、不同类型、指向不同页面的通知。
type AppealAppellantNotification struct {
	Type     string
	Content  string
	DedupKey string
	// PostScoped 表示通知应挂在 PostID 上。客户端据 post_id 直达帖子治理结果区，
	// 能同时看到恢复状态与「查看申诉详情」入口，而不是只落到公众法庭再自己找帖子。
	PostScoped bool
}

// ResolveAppealAppellantNotification 推导申诉人的主通知。
//
// 一次结案只产生一条。此前帖子类申诉同时发 appeal_result 与
// appeal_approved / appeal_rejected，作者会连续收到「申诉已通过」+
// 「申诉结案结果」两条指向同一件事的通知。
//
// 只有目标本身是帖子的申诉才改挂 PostID：回复类申诉的 PostID 只是所属帖子，
// 指向它并向申诉人宣称「帖子已恢复展示」是错的。
func ResolveAppealAppellantNotification(
	appeal Appeal,
	closedByHumanReview bool,
) AppealAppellantNotification {
	closed := appeal.Status == AppealStatusPass || appeal.Status == AppealStatusReject
	if appeal.TargetType == "post" && appeal.PostID > 0 && closed {
		if appeal.Status == AppealStatusPass {
			return AppealAppellantNotification{
				Type:       NotificationTypeAppealApproved,
				Content:    "经复核，帖子的限制已解除，现已恢复正常公开展示。",
				DedupKey:   fmt.Sprintf("appeal-approved:%d", appeal.ID),
				PostScoped: true,
			}
		}
		return AppealAppellantNotification{
			Type:       NotificationTypeAppealRejected,
			Content:    "申诉未通过：经复核原处理结果维持不变。你仍可以修改帖子后提交整改复审。",
			DedupKey:   fmt.Sprintf("appeal-rejected:%d", appeal.ID),
			PostScoped: true,
		}
	}
	if appeal.Status == AppealStatusReview {
		return AppealAppellantNotification{
			Type:     NotificationTypeAppealReviewRequired,
			Content:  "公众法庭案件已转交独立管理员复核，请等待最终结果。",
			DedupKey: fmt.Sprintf("appeal-review-required:%d:appellant", appeal.ID),
		}
	}
	content := "公众法庭案件已结案，请查看复核结果。"
	if closedByHumanReview {
		content = "人工复核已完成，请查看公众法庭案件结果。"
	}
	return AppealAppellantNotification{
		Type:     NotificationTypeAppealResult,
		Content:  content,
		DedupKey: fmt.Sprintf("appeal-result:%d:appellant", appeal.ID),
	}
}
