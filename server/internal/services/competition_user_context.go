package services

import (
	"encoding/json"

	"shenliyuan/internal/competitioncontext"

	"gorm.io/datatypes"
	"gorm.io/gorm"
)

type CompetitionCapabilitySummary = competitioncontext.CapabilitySummary
type CompetitionUserContext = competitioncontext.UserContext
type CompetitionUserContextBuilder = competitioncontext.Builder

func NewCompetitionUserContextBuilder(db *gorm.DB) *CompetitionUserContextBuilder {
	return competitioncontext.NewBuilder(db)
}

func decodeCompetitionStringArray(value datatypes.JSON) []string {
	if len(value) == 0 {
		return []string{}
	}
	var result []string
	if err := json.Unmarshal(value, &result); err != nil || result == nil {
		return []string{}
	}
	return result
}
