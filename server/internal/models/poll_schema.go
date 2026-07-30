package models

import (
	"fmt"

	"gorm.io/gorm"
)

// EnsurePollSchema 回填历史帖子并创建投票业务所需的幂等约束。
func EnsurePollSchema(db *gorm.DB) error {
	if db == nil {
		return fmt.Errorf("数据库连接不能为空")
	}
	if err := db.Exec(`UPDATE posts SET content_kind = ? WHERE content_kind IS NULL OR content_kind = ''`, PostContentKindNormal).Error; err != nil {
		return fmt.Errorf("回填帖子内容类型: %w", err)
	}
	if err := db.Exec(`UPDATE posts SET post_type = 'campus_life' WHERE board_id = ? AND content_kind = ? AND (post_type IS NULL OR post_type = '')`, BoardShuitie, PostContentKindNormal).Error; err != nil {
		return fmt.Errorf("回填普通水帖类型: %w", err)
	}

	indexes := []string{
		`CREATE UNIQUE INDEX IF NOT EXISTS idx_polls_post_id ON polls(post_id)`,
		`CREATE UNIQUE INDEX IF NOT EXISTS idx_poll_ballots_poll_user ON poll_ballots(poll_id, user_id)`,
		`CREATE UNIQUE INDEX IF NOT EXISTS idx_poll_ballot_choices_ballot_option ON poll_ballot_choices(ballot_id, option_id)`,
		`CREATE UNIQUE INDEX IF NOT EXISTS idx_poll_options_poll_sort ON poll_options(poll_id, sort_order)`,
		`CREATE INDEX IF NOT EXISTS idx_polls_list ON polls(status, category, ends_at, created_at)`,
		`CREATE INDEX IF NOT EXISTS idx_polls_last_vote ON polls(last_vote_at DESC)`,
	}
	for _, statement := range indexes {
		if err := db.Exec(statement).Error; err != nil {
			return fmt.Errorf("创建投票索引: %w", err)
		}
	}

	if db.Dialector.Name() != "postgres" {
		return nil
	}
	if err := db.Exec(
		`ALTER TABLE polls DROP CONSTRAINT IF EXISTS chk_polls_results_visibility`,
	).Error; err != nil {
		return fmt.Errorf("删除旧投票结果可见性约束: %w", err)
	}
	if err := db.Exec(`
		ALTER TABLE polls ADD CONSTRAINT chk_polls_results_visibility
		CHECK (results_visibility IN ('always', 'after_vote', 'after_end', 'private'))`,
	).Error; err != nil {
		return fmt.Errorf("更新投票结果可见性约束: %w", err)
	}
	constraints := []string{
		`ALTER TABLE polls ADD CONSTRAINT chk_polls_selection_mode CHECK (selection_mode IN ('single', 'multiple'))`,
		`ALTER TABLE polls ADD CONSTRAINT chk_polls_status CHECK (status IN ('active', 'closed', 'deleted'))`,
		`ALTER TABLE polls ADD CONSTRAINT chk_polls_participant_count CHECK (participant_count >= 0)`,
		`ALTER TABLE polls ADD CONSTRAINT chk_polls_choice_count CHECK (choice_count >= 0)`,
		`ALTER TABLE poll_options ADD CONSTRAINT chk_poll_options_vote_count CHECK (vote_count >= 0)`,
	}
	for _, statement := range constraints {
		// PostgreSQL 的 duplicate_object 代表约束已存在，迁移可安全重复执行。
		wrapped := `DO $$ BEGIN ` + statement + `; EXCEPTION WHEN duplicate_object THEN NULL; END $$;`
		if err := db.Exec(wrapped).Error; err != nil {
			return fmt.Errorf("创建投票约束: %w", err)
		}
	}
	return nil
}
