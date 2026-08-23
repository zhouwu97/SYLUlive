package services

import (
	"testing"
	"time"

	"github.com/glebarez/sqlite"
	"github.com/google/uuid"
	"gorm.io/gorm"

	"shenliyuan/internal/models"
)

func newTopicServiceTestDB(t *testing.T) *gorm.DB {
	t.Helper()
	db, err := gorm.Open(sqlite.Open("file:"+uuid.NewString()+"?mode=memory&cache=shared"), &gorm.Config{})
	if err != nil {
		t.Fatal(err)
	}
	if err := db.AutoMigrate(&models.Post{}, &models.Topic{}, &models.PostTopic{}); err != nil {
		t.Fatal(err)
	}
	return db
}

func TestNormalizeTopicName(t *testing.T) {
	tests := []struct {
		name    string
		input   string
		want    string
		wantErr bool
	}{
		{name: "plain", input: "宿舍", want: "宿舍"},
		{name: "hash", input: "#宿舍", want: "宿舍"},
		{name: "full hash", input: "＃宿舍", want: "宿舍"},
		{name: "spaces", input: "  宿舍\u00a0生活  ", want: "宿舍 生活"},
		{name: "ascii", input: "C++", want: "C++"},
		{name: "punctuation", input: "###", wantErr: true},
		{name: "newline", input: "宿舍\n生活", wantErr: true},
		{name: "too long", input: "一二三四五六七八九十一二三四五六七八九十一", wantErr: true},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got, err := NormalizeTopicName(tt.input)
			if tt.wantErr {
				if err == nil {
					t.Fatalf("expected error, got %q", got)
				}
				return
			}
			if err != nil || got != tt.want {
				t.Fatalf("NormalizeTopicName(%q) = %q, %v; want %q", tt.input, got, err, tt.want)
			}
		})
	}
}

func TestReplacePostTopicsDistinguishesMissingAndEmpty(t *testing.T) {
	db := newTopicServiceTestDB(t)
	post := models.Post{Content: "hello", AuthorID: 1, CreatedAt: nowForTopicTest()}
	if err := db.Create(&post).Error; err != nil {
		t.Fatal(err)
	}
	if err := db.Transaction(func(tx *gorm.DB) error {
		return ReplacePostTopics(tx, post.ID, []TopicSelection{{Name: "宿舍"}}, true)
	}); err != nil {
		t.Fatal(err)
	}
	if err := ReplacePostTopics(db, post.ID, nil, false); err != nil {
		t.Fatal(err)
	}
	var links []models.PostTopic
	if err := db.Where("post_id = ?", post.ID).Find(&links).Error; err != nil {
		t.Fatal(err)
	}
	if len(links) != 1 {
		t.Fatalf("missing topics_json should preserve links, got %d", len(links))
	}
	if err := ReplacePostTopics(db, post.ID, nil, true); err != nil {
		t.Fatal(err)
	}
	if err := db.Where("post_id = ?", post.ID).Find(&links).Error; err != nil {
		t.Fatal(err)
	}
	if len(links) != 0 {
		t.Fatalf("empty topics_json should clear links, got %d", len(links))
	}
}

func TestLoadTopicsForPostsBatch(t *testing.T) {
	db := newTopicServiceTestDB(t)
	posts := []models.Post{
		{Content: "one", AuthorID: 1, CreatedAt: nowForTopicTest()},
		{Content: "two", AuthorID: 1, CreatedAt: nowForTopicTest()},
	}
	if err := db.Create(&posts).Error; err != nil {
		t.Fatal(err)
	}
	if err := db.Transaction(func(tx *gorm.DB) error {
		if err := ReplacePostTopics(tx, posts[0].ID, []TopicSelection{{Name: "宿舍"}, {Name: "研究生"}}, true); err != nil {
			return err
		}
		return ReplacePostTopics(tx, posts[1].ID, []TopicSelection{{Name: "宿舍"}}, true)
	}); err != nil {
		t.Fatal(err)
	}
	if err := LoadTopicsForPosts(db, posts); err != nil {
		t.Fatal(err)
	}
	if len(posts[0].Topics) != 2 || posts[0].Topics[0].Name != "宿舍" {
		t.Fatalf("unexpected first post topics: %+v", posts[0].Topics)
	}
	if len(posts[1].Topics) != 1 || posts[1].Topics[0].Name != "宿舍" {
		t.Fatalf("unexpected second post topics: %+v", posts[1].Topics)
	}
}

func nowForTopicTest() (now time.Time) { return time.Now() }
