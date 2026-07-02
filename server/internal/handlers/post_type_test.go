package handlers

import (
	"testing"

	"shenliyuan/internal/models"
)

func TestNormalizeWaterPostType(t *testing.T) {
	tests := []struct {
		name    string
		boardID models.BoardID
		input   string
		want    string
		wantErr bool
	}{
		{
			name:    "empty water post falls back to campus life",
			boardID: models.BoardShuitie,
			input:   "",
			want:    "campus_life",
		},
		{
			name:    "valid water post type is preserved",
			boardID: models.BoardShuitie,
			input:   "competition",
			want:    "competition",
		},
		{
			name:    "invalid water post type is rejected",
			boardID: models.BoardShuitie,
			input:   "admin",
			wantErr: true,
		},
		{
			name:    "market post type keeps original semantics",
			boardID: models.BoardMarket,
			input:   "sell",
			want:    "sell",
		},
		{
			name:    "market empty post type remains empty",
			boardID: models.BoardMarket,
			input:   "",
			want:    "",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got, err := normalizeWaterPostType(tt.boardID, tt.input)
			if tt.wantErr {
				if err == nil {
					t.Fatal("expected error, got nil")
				}
				return
			}
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			if got != tt.want {
				t.Fatalf("got %q, want %q", got, tt.want)
			}
		})
	}
}
