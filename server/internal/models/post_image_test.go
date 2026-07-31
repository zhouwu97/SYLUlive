package models

import (
	"encoding/json"
	"testing"
)

func TestPostImageMarshalJSONIncludesImageVariants(t *testing.T) {
	payload, err := json.Marshal(PostImage{
		ID: 1,
		File: File{
			Path:     "/uploads/ab/hash.jpg",
			MimeType: "image/jpeg",
		},
	})
	if err != nil {
		t.Fatal(err)
	}
	var value map[string]any
	if err := json.Unmarshal(payload, &value); err != nil {
		t.Fatal(err)
	}
	if value["thumb_url"] != "/uploads/ab/hash_thumb.jpg" ||
		value["medium_url"] != "/uploads/ab/hash_medium.jpg" ||
		value["origin_url"] != "/uploads/ab/hash.jpg" {
		t.Fatalf("图片三档地址错误: %s", payload)
	}
}

func TestPostImageMarshalJSONKeepsGIFOriginal(t *testing.T) {
	payload, err := json.Marshal(PostImage{
		File: File{
			Path:     "/uploads/ab/hash.gif",
			MimeType: "image/gif",
		},
	})
	if err != nil {
		t.Fatal(err)
	}
	var value map[string]any
	if err := json.Unmarshal(payload, &value); err != nil {
		t.Fatal(err)
	}
	if value["thumb_url"] != "/uploads/ab/hash.gif" ||
		value["medium_url"] != "/uploads/ab/hash.gif" {
		t.Fatalf("GIF 应回退到原图: %s", payload)
	}
}
