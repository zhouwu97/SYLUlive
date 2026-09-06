package handlers

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strconv"
	"strings"
	"testing"

	"github.com/gin-gonic/gin"

	"shenliyuan/internal/models"
)

func TestNormalizeMarketContact(t *testing.T) {
	tests := []struct {
		name        string
		boardID     models.BoardID
		contactType string
		contact     string
		wantType    models.MarketContactType
		wantContact string
		wantError   string
	}{
		{name: "微信", boardID: models.BoardMarket, contactType: "wechat", contact: " wx_123 ", wantType: models.MarketContactTypeWeChat, wantContact: "wx_123"},
		{name: "QQ", boardID: models.BoardMarket, contactType: "qq", contact: "123456789", wantType: models.MarketContactTypeQQ, wantContact: "123456789"},
		{name: "电话", boardID: models.BoardMarket, contactType: "phone", contact: "+86 138-0013-8000", wantType: models.MarketContactTypePhone, wantContact: "+86 138-0013-8000"},
		{name: "全部为空", boardID: models.BoardMarket},
		{name: "旧客户端微信", boardID: models.BoardMarket, contact: "微信：wx123", wantType: models.MarketContactTypeWeChat, wantContact: "wx123"},
		{name: "旧客户端QQ后缀", boardID: models.BoardMarket, contact: "123456789（QQ）", wantType: models.MarketContactTypeQQ, wantContact: "123456789"},
		{name: "旧客户端纯账号", boardID: models.BoardMarket, contact: "wx123", wantType: models.MarketContactTypeOther, wantContact: "wx123"},
		{name: "旧客户端纯数字", boardID: models.BoardMarket, contact: "123456789", wantType: models.MarketContactTypeOther, wantContact: "123456789"},
		{name: "缺少账号", boardID: models.BoardMarket, contactType: "wechat", wantError: "请输入微信号"},
		{name: "非法类型", boardID: models.BoardMarket, contactType: "other", contact: "abc", wantError: "不支持的联系方式类型"},
		{name: "微信格式", boardID: models.BoardMarket, contactType: "wechat", contact: "微信abc", wantError: "微信号格式不正确"},
		{name: "QQ格式", boardID: models.BoardMarket, contactType: "qq", contact: "123abc", wantError: "QQ号格式不正确"},
		{name: "电话格式", boardID: models.BoardMarket, contactType: "phone", contact: "138abc", wantError: "电话号码格式不正确"},
		{name: "非集市清空", boardID: models.BoardShuitie, contactType: "wechat", contact: "wx123"},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			gotType, gotContact, err := normalizeMarketContact(tt.boardID, tt.contactType, tt.contact)
			if tt.wantError != "" {
				if err == nil || err.Error() != tt.wantError {
					t.Fatalf("error=%v, want %q", err, tt.wantError)
				}
				return
			}
			if err != nil {
				t.Fatalf("normalize contact: %v", err)
			}
			if gotType != tt.wantType || gotContact != tt.wantContact {
				t.Fatalf("got (%q, %q), want (%q, %q)", gotType, gotContact, tt.wantType, tt.wantContact)
			}
		})
	}
}

func TestCreateAndUpdateMarketPostContact(t *testing.T) {
	db := newMarketTagsTestDB(t)
	user := createMarketTagsTestUser(t, db, "20260718")
	image := createMarketTagsTestImage(t, db, user.ID)
	handler := NewPostHandler(db, "", "")

	createForm := url.Values{
		"board_id":     {"2"},
		"title":        {"显示器"},
		"content":      {"成色很好"},
		"post_type":    {"sell"},
		"contact_type": {"wechat"},
		"contact":      {" wx_123 "},
		"file_ids":     {strconv.FormatUint(uint64(image.ID), 10)},
	}
	recorder := performMarketContactRequest(t, handler.Create, user.ID, 0, createForm)
	if recorder.Code != http.StatusCreated {
		t.Fatalf("create status=%d body=%s", recorder.Code, recorder.Body.String())
	}
	var created models.Post
	if err := json.Unmarshal(recorder.Body.Bytes(), &created); err != nil {
		t.Fatalf("decode create response: %v", err)
	}
	if created.ContactType != models.MarketContactTypeWeChat || created.Contact != "wx_123" {
		t.Fatalf("created contact=(%q, %q)", created.ContactType, created.Contact)
	}

	updateForm := url.Values{
		"title":        {"显示器"},
		"content":      {"成色很好"},
		"post_type":    {"sell"},
		"contact_type": {"phone"},
		"contact":      {"138 0013-8000"},
	}
	recorder = performMarketContactRequest(t, handler.Update, user.ID, created.ID, updateForm)
	if recorder.Code != http.StatusOK {
		t.Fatalf("update status=%d body=%s", recorder.Code, recorder.Body.String())
	}
	var updated models.Post
	if err := json.Unmarshal(recorder.Body.Bytes(), &updated); err != nil {
		t.Fatalf("decode update response: %v", err)
	}
	if updated.ContactType != models.MarketContactTypePhone || updated.Contact != "138 0013-8000" {
		t.Fatalf("updated contact=(%q, %q)", updated.ContactType, updated.Contact)
	}

	updateForm.Set("contact_type", "")
	updateForm.Set("contact", "")
	recorder = performMarketContactRequest(t, handler.Update, user.ID, created.ID, updateForm)
	if recorder.Code != http.StatusOK {
		t.Fatalf("clear status=%d body=%s", recorder.Code, recorder.Body.String())
	}
	if err := db.First(&updated, created.ID).Error; err != nil {
		t.Fatalf("load cleared post: %v", err)
	}
	if updated.ContactType != "" || updated.Contact != "" {
		t.Fatalf("cleared contact=(%q, %q)", updated.ContactType, updated.Contact)
	}
}

func TestLegacyClientCreateAndUpdateMarketPostContact(t *testing.T) {
	db := newMarketTagsTestDB(t)
	user := createMarketTagsTestUser(t, db, "20260719")
	image := createMarketTagsTestImage(t, db, user.ID)
	handler := NewPostHandler(db, "", "")

	createForm := url.Values{
		"board_id":  {"2"},
		"title":     {"旧客户端发布"},
		"content":   {"测试内容"},
		"post_type": {"sell"},
		"contact":   {"微信：legacy_wx"},
		"file_ids":  {strconv.FormatUint(uint64(image.ID), 10)},
	}
	recorder := performMarketContactRequest(t, handler.Create, user.ID, 0, createForm)
	if recorder.Code != http.StatusCreated {
		t.Fatalf("legacy create status=%d body=%s", recorder.Code, recorder.Body.String())
	}
	var created models.Post
	if err := json.Unmarshal(recorder.Body.Bytes(), &created); err != nil {
		t.Fatalf("decode legacy create response: %v", err)
	}
	if created.ContactType != models.MarketContactTypeWeChat || created.Contact != "legacy_wx" {
		t.Fatalf("legacy created contact=(%q, %q)", created.ContactType, created.Contact)
	}

	updateForm := url.Values{
		"title":     {"旧客户端编辑"},
		"content":   {"更新内容"},
		"post_type": {"sell"},
		"contact":   {"unrecognized_account"},
	}
	recorder = performMarketContactRequest(t, handler.Update, user.ID, created.ID, updateForm)
	if recorder.Code != http.StatusOK {
		t.Fatalf("legacy update status=%d body=%s", recorder.Code, recorder.Body.String())
	}
	var updated models.Post
	if err := json.Unmarshal(recorder.Body.Bytes(), &updated); err != nil {
		t.Fatalf("decode legacy update response: %v", err)
	}
	if updated.ContactType != models.MarketContactTypeOther || updated.Contact != "unrecognized_account" {
		t.Fatalf("legacy updated contact=(%q, %q)", updated.ContactType, updated.Contact)
	}
}

func TestCreateMarketPostRejectsExplicitInvalidContactType(t *testing.T) {
	db := newMarketTagsTestDB(t)
	user := createMarketTagsTestUser(t, db, "20260720")
	form := url.Values{
		"board_id":     {"2"},
		"content":      {"测试内容"},
		"contact_type": {"invalid"},
		"contact":      {"wx123"},
	}
	recorder := performMarketContactRequest(t, NewPostHandler(db, "", "").Create, user.ID, 0, form)
	if recorder.Code != http.StatusBadRequest || !strings.Contains(recorder.Body.String(), "不支持的联系方式类型") {
		t.Fatalf("status=%d body=%s", recorder.Code, recorder.Body.String())
	}
}

func performMarketContactRequest(
	t *testing.T,
	handler gin.HandlerFunc,
	userID uint,
	postID uint,
	form url.Values,
) *httptest.ResponseRecorder {
	t.Helper()
	recorder := httptest.NewRecorder()
	context, _ := gin.CreateTestContext(recorder)
	context.Set("user_id", userID)
	context.Set("role", "user")
	method := http.MethodPost
	path := "/api/posts"
	if postID != 0 {
		method = http.MethodPut
		path += "/" + strconv.FormatUint(uint64(postID), 10)
		context.Params = gin.Params{{Key: "id", Value: strconv.FormatUint(uint64(postID), 10)}}
	}
	context.Request = httptest.NewRequest(method, path, strings.NewReader(form.Encode()))
	context.Request.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	handler(context)
	return recorder
}
