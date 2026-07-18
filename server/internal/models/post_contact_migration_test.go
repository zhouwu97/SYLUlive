package models

import (
	"strings"
	"testing"

	"github.com/glebarez/sqlite"
	"gorm.io/gorm"
)

func TestBackfillLegacyMarketContacts(t *testing.T) {
	dbName := strings.ReplaceAll(t.Name(), "/", "_")
	db, err := gorm.Open(sqlite.Open("file:"+dbName+"?mode=memory&cache=shared"), &gorm.Config{})
	if err != nil {
		t.Fatalf("open database: %v", err)
	}
	if err := db.AutoMigrate(&Post{}); err != nil {
		t.Fatalf("migrate database: %v", err)
	}

	posts := []Post{
		{BoardID: BoardMarket, AuthorID: 1, Contact: "WI665301822（微信）"},
		{BoardID: BoardMarket, AuthorID: 1, Contact: "QQ号：123456789"},
		{BoardID: BoardMarket, AuthorID: 1, Contact: "13800138000 (电话)"},
		{BoardID: BoardMarket, AuthorID: 1, Contact: "123456789"},
		{BoardID: BoardMarket, AuthorID: 1, ContactType: MarketContactTypeWeChat, Contact: "keep_me"},
		{BoardID: BoardShuitie, AuthorID: 1, Contact: "微信：ignore_me"},
	}
	if err := db.Create(&posts).Error; err != nil {
		t.Fatalf("seed posts: %v", err)
	}

	if err := BackfillLegacyMarketContacts(db); err != nil {
		t.Fatalf("backfill contacts: %v", err)
	}
	if err := BackfillLegacyMarketContacts(db); err != nil {
		t.Fatalf("repeat backfill contacts: %v", err)
	}

	var got []Post
	if err := db.Order("id ASC").Find(&got).Error; err != nil {
		t.Fatalf("load posts: %v", err)
	}
	wants := []struct {
		contactType MarketContactType
		contact     string
	}{
		{MarketContactTypeWeChat, "WI665301822"},
		{MarketContactTypeQQ, "123456789"},
		{MarketContactTypePhone, "13800138000"},
		{MarketContactTypeOther, "123456789"},
		{MarketContactTypeWeChat, "keep_me"},
		{"", "微信：ignore_me"},
	}
	for i, want := range wants {
		if got[i].ContactType != want.contactType || got[i].Contact != want.contact {
			t.Errorf("post %d contact=(%q, %q), want (%q, %q)", i, got[i].ContactType, got[i].Contact, want.contactType, want.contact)
		}
	}
}
