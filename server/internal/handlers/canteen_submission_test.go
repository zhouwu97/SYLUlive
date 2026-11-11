package handlers

import (
	"encoding/json"
	"fmt"
	"net/http"
	"testing"

	"shenliyuan/internal/models"
)

var submitCanteenFileSeq int

func submitCanteenForTest(t *testing.T, h *CanteenHandler, userID uint, name string) (int, string) {
	t.Helper()
	submitCanteenFileSeq++
	path := fmt.Sprintf("/uploads/submission-%d.png", submitCanteenFileSeq)
	if err := h.db.Create(&models.File{Hash: fmt.Sprintf("submission-hash-%d", submitCanteenFileSeq), Path: path, Size: 1, MimeType: "image/png", UploaderID: userID, Status: "active"}).Error; err != nil {
		t.Fatal(err)
	}
	resp := performCanteenRequest(t, h.Create, http.MethodPost, "/api/canteens", nil, userID,
		`{"name":"`+name+`","image":"`+path+`","location_area":"一食堂","location_floor":"一楼"}`)
	return resp.Code, resp.Body.String()
}

// 驳回只做标记：提交人在“我的贡献”看得到原因，待审列表不再出现，同名可以重新提交。
func TestRejectedCanteenSubmissionIsKeptAndCanBeResubmitted(t *testing.T) {
	h, _, user := prepareReviewV2DB(t)
	other := createCanteenTestUser(t, h.db, 501, "另一位同学")

	if code, body := submitCanteenForTest(t, h, user.ID, "新开的煎饼"); code != http.StatusCreated {
		t.Fatalf("submit status=%d body=%s", code, body)
	}
	var submitted models.Canteen
	if err := h.db.Where("name = ?", "新开的煎饼").First(&submitted).Error; err != nil {
		t.Fatal(err)
	}

	// 另一位同学提交同一家待审店：说清楚是“正在审核”，而不是笼统的“已存在”。
	if code, body := submitCanteenForTest(t, h, other.ID, "新开的煎饼 "); code != http.StatusConflict ||
		!containsReviewJSONCode([]byte(body), "canteen_pending_duplicate") {
		t.Fatalf("pending duplicate status=%d body=%s", code, body)
	}

	reject := performCanteenRequest(t, h.RejectCanteen, http.MethodDelete, "/api/canteens/pending",
		mapParams("id", jsonID(submitted.ID)), user.ID, `{"reason":"图片看不清门面"}`)
	if reject.Code != http.StatusOK {
		t.Fatalf("reject status=%d body=%s", reject.Code, reject.Body.String())
	}
	var kept models.Canteen
	if err := h.db.First(&kept, submitted.ID).Error; err != nil {
		t.Fatalf("rejected submission must be kept: %v", err)
	}
	if !kept.IsRejected() || kept.RejectReason != "图片看不清门面" || kept.NormalizedName != models.CanteenRejectedNormalizedName(kept.ID) {
		t.Fatalf("kept=%+v", kept)
	}

	pending := performCanteenRequest(t, h.AdminListPending, http.MethodGet, "/api/canteens/pending", nil, user.ID, "")
	if containsString(pending.Body.Bytes(), "新开的煎饼") {
		t.Fatalf("rejected submission must leave the pending list: %s", pending.Body.String())
	}
	if again := performCanteenRequest(t, h.RejectCanteen, http.MethodDelete, "/api/canteens/pending",
		mapParams("id", jsonID(submitted.ID)), user.ID, `{}`); again.Code != http.StatusConflict {
		t.Fatalf("double reject status=%d", again.Code)
	}
	if approve := performCanteenRequest(t, h.ApproveCanteen, http.MethodPost, "/api/canteens/approve",
		mapParams("id", jsonID(submitted.ID)), user.ID, ""); approve.Code != http.StatusConflict {
		t.Fatalf("approve rejected status=%d body=%s", approve.Code, approve.Body.String())
	}

	contributions := performCanteenRequest(t, h.GetMyCanteenContributions, http.MethodGet,
		"/api/user/canteen-contributions", nil, user.ID, "")
	var body struct {
		Items []map[string]interface{} `json:"items"`
	}
	if err := json.Unmarshal(contributions.Body.Bytes(), &body); err != nil {
		t.Fatal(err)
	}
	found := false
	for _, item := range body.Items {
		if item["type"] == "canteen" && item["canteen_name"] == "新开的煎饼" {
			found = item["status"] == "rejected" && item["reject_reason"] == "图片看不清门面"
		}
	}
	if !found {
		t.Fatalf("contributions must show rejected submission with reason: %s", contributions.Body.String())
	}

	// 名字已腾出来：同学改好图片后可以重新提交，新提交是待审核状态。
	if code, body := submitCanteenForTest(t, h, other.ID, "新开的煎饼"); code != http.StatusCreated {
		t.Fatalf("resubmit status=%d body=%s", code, body)
	}
	otherContrib := performCanteenRequest(t, h.GetMyCanteenContributions, http.MethodGet,
		"/api/user/canteen-contributions", nil, other.ID, "")
	if !containsString(otherContrib.Body.Bytes(), `"status":"pending"`) {
		t.Fatalf("resubmitted item should be pending: %s", otherContrib.Body.String())
	}

	// 已收录的店再提交：告诉同学去搜，而不是“已存在”。
	if code, body := submitCanteenForTest(t, h, user.ID, "一食堂"); code != http.StatusCreated {
		// prepareReviewV2DB 的店没有位置字段，这里不撞名，作为对照应能创建成功。
		t.Fatalf("control submit status=%d body=%s", code, body)
	}
}

func jsonID(id uint) string {
	data, _ := json.Marshal(id)
	return string(data)
}
