package ai

import (
	"context"
	"encoding/json"
	"fmt"
	"testing"

	"github.com/stretchr/testify/require"
	"shenliyuan/internal/models"
)

func TestCommunityPublicAuthorsCountsRankCursorAndMedia(t *testing.T) {
	db := communityTestDB(t)
	require.NoError(t, db.Create(&models.User{ID: 1, Nickname: "公开昵称", PasswordHash: "private-password", StudentID: "private-student", Email: "private-email"}).Error)
	for _, id := range []uint{1, 2, 3, 4} {
		p := communityTestPost(t, db, id)
		require.NoError(t, db.Model(&p).Updates(map[string]interface{}{"like_count": 10, "reply_count": int(id)}).Error)
	}
	require.NoError(t, db.Model(&models.Post{}).Where("id=1").Update("like_count", 99).Error)
	for i, scope := range []models.FileAccessScope{models.FileAccessPublic, models.FileAccessPrivate} {
		f := models.File{ID: uint(i + 1), Hash: fmt.Sprint(i), Path: fmt.Sprintf("/uploads/synthetic-%d.png", i), MimeType: "image/png", Width: 20, Height: 10, Status: models.FileStatusActive, AccessScope: scope}
		require.NoError(t, db.Create(&f).Error)
		require.NoError(t, db.Create(&models.PostImage{PostID: 1, FileID: f.ID, SortOrder: i}).Error)
	}
	tools := NewCampusMCPTools(db, nil, nil, WithCampusCommunityReadTools(nil))
	page := communityTestRead(t, tools, "community.list_feed", `{"sort":"likes","limit":2}`).Data.(map[string]interface{})
	items := page["items"].([]communityPostView)
	require.Equal(t, []uint{1, 4}, []uint{items[0].PostID, items[1].PostID})
	require.Equal(t, 99, items[0].LikeCount)
	require.Equal(t, "公开昵称", items[0].Author.Nickname)
	require.Len(t, items[0].Images, 1)
	require.Equal(t, "/uploads/synthetic-0.png", items[0].Images[0].URL)
	require.Zero(t, page["next_after_id"])
	cursor := page["next_cursor"].(string)
	page2 := communityTestRead(t, tools, "community.list_feed", fmt.Sprintf(`{"sort":"likes","limit":2,"cursor":%q}`, cursor)).Data.(map[string]interface{})
	second := page2["items"].([]communityPostView)
	require.Equal(t, []uint{3, 2}, []uint{second[0].PostID, second[1].PostID})
	require.Empty(t, page2["next_cursor"])
	page3 := communityTestRead(t, tools, "community.list_feed", `{"sort":"replies","limit":1}`).Data.(map[string]interface{})
	require.EqualValues(t, 4, page3["items"].([]communityPostView)[0].PostID)
	for _, args := range []string{`{"sort":"invalid"}`, `{"sort":"likes","after_id":1}`, `{"sort":"newest","cursor":"x"}`, `{"sort":"likes","cursor":"bad"}`, fmt.Sprintf(`{"sort":"replies","cursor":%q}`, cursor)} {
		_, err := campusToolByName(t, tools, "community.list_feed").Execute(context.Background(), 7, json.RawMessage(args))
		require.Error(t, err, args)
	}
	raw, err := json.Marshal(page)
	require.NoError(t, err)
	for _, secret := range []string{"private-password", "private-student", "private-email", "author_id", "uploader_id", "private-1", "file_id", "view_count"} {
		require.NotContains(t, string(raw), secret)
	}
	version := items[0].SourceVersion
	require.NoError(t, db.Model(&models.User{}).Where("id=1").Update("nickname", "改名后").Error)
	post := communityTestRead(t, tools, "community.get_post", `{"post_id":1}`).Data.(communityPostView)
	require.Equal(t, "改名后", post.Author.Nickname)
	require.Equal(t, version, post.SourceVersion)
	require.NoError(t, db.Model(&models.File{}).Where("id=1").Update("access_scope", models.FileAccessPrivate).Error)
	post = communityTestRead(t, tools, "community.get_post", `{"post_id":1}`).Data.(communityPostView)
	require.Empty(t, post.Images)
	require.NoError(t, db.Model(&models.User{}).Where("id=1").Update("account_status", "cancelled").Error)
	post = communityTestRead(t, tools, "community.get_post", `{"post_id":1}`).Data.(communityPostView)
	require.Equal(t, "已注销用户", post.Author.Nickname)
	var stored models.Post
	require.NoError(t, db.First(&stored, 1).Error)
	require.Equal(t, 17, stored.ViewCount)
}
