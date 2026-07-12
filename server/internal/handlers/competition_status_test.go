package handlers

import (
	"testing"
)

func TestCheckEventStatusTransition(t *testing.T) {
	tests := []struct {
		currentStatus string
		action        string
		expected      string
		expectErr     bool
	}{
		// Draft
		{"draft", "publish", "published", false},
		{"draft", "archive", "archived", false},
		{"draft", "delete", "deleted", false},
		{"draft", "restore_to_draft", "", true}, // cannot restore draft

		// Published
		{"published", "archive", "archived", false},
		{"published", "delete", "", true},           // cannot delete published
		{"published", "restore_to_draft", "", true}, // cannot restore published
		{"published", "publish", "", true},          // cannot publish published

		// Archived
		{"archived", "restore_to_draft", "draft", false},
		{"archived", "delete", "deleted", false},
		{"archived", "publish", "", true}, // cannot directly publish archived
		{"archived", "archive", "", true}, // cannot archive archived
	}

	for _, tt := range tests {
		t.Run(tt.currentStatus+"_"+tt.action, func(t *testing.T) {
			result, err := checkEventStatusTransition(tt.currentStatus, tt.action)
			if (err != nil) != tt.expectErr {
				t.Errorf("expected error: %v, got error: %v", tt.expectErr, err)
			}
			if !tt.expectErr && result != tt.expected {
				t.Errorf("expected %s, got %s", tt.expected, result)
			}
		})
	}
}
