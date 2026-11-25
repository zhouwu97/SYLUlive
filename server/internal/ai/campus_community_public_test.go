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

func TestCommunityChronologicalPostPagination(t *testing.T) {
	db := communityTestDB(t)
	for _, id := range []uint{1, 3, 5, 7, 9, 11} {
		communityTestPost(t, db, id)
	}
	require.NoError(t, db.Model(&models.Post{}).Where("id = ?", 1).Update("status", models.PostStatusModeratedHidden).Error)
	require.NoError(t, db.Model(&models.Post{}).Where("id = ?", 7).Update("status", models.PostStatusDeleted).Error)
	require.NoError(t, db.Model(&models.Post{}).Where("id IN ?", []uint{5, 9}).Update("title", "限定学习讨论").Error)
	tools := NewCampusMCPTools(db, nil, nil, WithCampusCommunityReadTools(nil))
	for _, tc := range []struct {
		name, tool, args string
		ids              []uint
		next             uint
	}{
		{"oldest_first_page", "community.list_feed", `{"sort":"oldest","limit":2}`, []uint{3, 5}, 5},
		{"oldest_next_page", "community.list_feed", `{"sort":"oldest","limit":2,"after_id":5}`, []uint{9, 11}, 0},
		{"oldest_end", "community.list_feed", `{"sort":"oldest","after_id":11}`, []uint{}, 0},
		{"newest_default", "community.list_feed", `{"limit":2}`, []uint{11, 9}, 9},
		{"newest_next_page", "community.list_feed", `{"sort":"newest","limit":2,"after_id":9}`, []uint{5, 3}, 0},
		{"oldest_search", "community.search_posts", `{"query":"限定","sort":"oldest","limit":2}`, []uint{5, 9}, 0},
	} {
		t.Run(tc.name, func(t *testing.T) {
			page := communityTestRead(t, tools, tc.tool, tc.args).Data.(map[string]interface{})
			ids := []uint{}
			for _, post := range page["items"].([]communityPostView) {
				ids = append(ids, post.PostID)
			}
			require.Equal(t, tc.ids, ids)
			require.Equal(t, tc.next, page["next_after_id"])
			require.Empty(t, page["next_cursor"])
		})
	}
	_, err := campusToolByName(t, tools, "community.list_feed").Execute(context.Background(), 7, json.RawMessage(`{"sort":"oldest","cursor":"unexpected"}`))
	require.Error(t, err)
}
