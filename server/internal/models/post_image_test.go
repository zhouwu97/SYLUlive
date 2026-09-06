package models

import (
	"encoding/json"
	"testing"
)

func TestPostImageMarshalJSONFallsBackUntilVariantsAreReady(t *testing.T) {
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
	if value["thumb_url"] != "/uploads/ab/hash.jpg" ||
		value["medium_url"] != "/uploads/ab/hash.jpg" ||
		value["origin_url"] != "/uploads/ab/hash.jpg" {
		t.Fatalf("未就绪图片应回退原图: %s", payload)
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

func TestPostImageMarshalJSONUsesReadyStaticGIFPreview(t *testing.T) {
	payload, err := json.Marshal(PostImage{
		FileID: 9,
		File:   File{Path: "/uploads/ab/hash.gif", MimeType: "image/gif"},
		Variants: []ImageVariant{{
			FileID: 9, Variant: "thumb", RecipeVersion: 1,
			Status: ImageVariantStatusReady,
			Path:   "/uploads/ab/hash_v1_thumb.jpg", MimeType: "image/jpeg",
		}},
	})
	if err != nil {
		t.Fatal(err)
	}
	var value map[string]any
	if err := json.Unmarshal(payload, &value); err != nil {
		t.Fatal(err)
	}
	if value["thumb_url"] != "/uploads/ab/hash_v1_thumb.jpg" ||
		value["origin_url"] != "/uploads/ab/hash.gif" {
		t.Fatalf("GIF 静态预览与原图 URL 错误: %s", payload)
	}
}

func TestPostImageMarshalJSONUsesReadyVersionedVariants(t *testing.T) {
	payload, err := json.Marshal(PostImage{
		FileID: 9,
		File:   File{Path: "/uploads/ab/hash.png", MimeType: "image/png"},
		Variants: []ImageVariant{
			{FileID: 9, Variant: "thumb", RecipeVersion: 1, Status: ImageVariantStatusReady, Path: "/uploads/ab/hash_v1_thumb.png"},
			{FileID: 9, Variant: "medium", RecipeVersion: 1, Status: ImageVariantStatusFailed, Path: "/uploads/ab/hash_v1_medium.png"},
		},
	})
	if err != nil {
		t.Fatal(err)
	}
	var value map[string]any
	if err := json.Unmarshal(payload, &value); err != nil {
		t.Fatal(err)
	}
	if value["thumb_url"] != "/uploads/ab/hash_v1_thumb.png" || value["medium_url"] != "/uploads/ab/hash.png" {
		t.Fatalf("ready 与 failed URL 错误: %s", payload)
	}
	statuses, ok := value["variant_status"].(map[string]any)
	if !ok || statuses["thumb"] != "ready" || statuses["medium"] != "failed" {
		t.Fatalf("变体状态错误: %s", payload)
	}
}

func TestReplyImageMarshalJSONUsesReadyVersionedVariants(t *testing.T) {
	payload, err := json.Marshal(ReplyImage{
		ReplyID: 3,
		FileID:  9,
		File:    File{Path: "/uploads/ab/reply.jpg", MimeType: "image/jpeg"},
		Variants: []ImageVariant{{FileID: 9, Variant: "thumb", RecipeVersion: 1,
			Status: ImageVariantStatusReady, Path: "/uploads/ab/reply_v1_thumb.jpg"}},
	})
	if err != nil {
		t.Fatal(err)
	}
	var value map[string]any
	if err := json.Unmarshal(payload, &value); err != nil {
		t.Fatal(err)
	}
	if value["thumb_url"] != "/uploads/ab/reply_v1_thumb.jpg" || value["medium_url"] != "/uploads/ab/reply.jpg" {
		t.Fatalf("回复图片变体 URL 错误: %s", payload)
	}
}
