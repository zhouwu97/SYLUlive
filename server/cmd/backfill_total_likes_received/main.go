// 校准兼容列快照；在线资料与明细始终以当前有效点赞事实为准。
// 默认只预览。连接只来自显式指定的环境变量，不读取应用配置或生产 .env。
package main

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"strings"
	"time"

	"github.com/glebarez/sqlite"
	"gorm.io/driver/postgres"
	"gorm.io/gorm"
	"gorm.io/gorm/logger"

	"shenliyuan/internal/models"
)

type snapshotChange struct {
	UserID uint `json:"user_id"`
	Before int  `json:"before"`
	After  int  `json:"after"`
}

type snapshotReport struct {
	Applied bool             `json:"applied"`
	Users   int              `json:"users"`
	Changed int              `json:"changed"`
	Changes []snapshotChange `json:"changes"`
}

func rebuildSnapshot(ctx context.Context, db *gorm.DB, apply bool) (snapshotReport, error) {
	report := snapshotReport{Applied: apply, Changes: make([]snapshotChange, 0)}
	err := db.WithContext(ctx).Transaction(func(tx *gorm.DB) error {
		if apply {
			switch tx.Dialector.Name() {
			case "postgres":
				// 所有事实表一起锁定，防止批次间漂移或覆盖并发增量；应在停写窗口执行。
				if err := tx.Exec("LOCK TABLE users, posts, replies, likes IN SHARE ROW EXCLUSIVE MODE").Error; err != nil {
					return err
				}
			case "sqlite":
				// 在读取前取得 SQLite 写锁；不修改任何业务行。
				if err := tx.Exec("UPDATE users SET total_likes_received = total_likes_received WHERE 1 = 0").Error; err != nil {
					return err
				}
			default:
				return errors.New("不支持的数据库")
			}
		}
		// 使用轻量行而非 User，避免 AfterFind 把待比较的旧快照覆盖掉。
		var users []struct {
			ID                 uint
			TotalLikesReceived int
		}
		if err := tx.Table("users").Select("id", "total_likes_received").Order("id").Scan(&users).Error; err != nil {
			return err
		}
		report.Users = len(users)
		for start := 0; start < len(users); start += 500 {
			batch := users[start:min(start+500, len(users))]
			ids := make([]uint, len(batch))
			for i, user := range batch {
				ids[i] = user.ID
			}
			counts, err := models.ReceivedLikeCounts(tx, ids)
			if err != nil {
				return err
			}
			for _, user := range batch {
				total := counts[user.ID]
				if total == user.TotalLikesReceived {
					continue
				}
				report.Changes = append(report.Changes, snapshotChange{user.ID, user.TotalLikesReceived, total})
				if apply {
					result := tx.Model(&models.User{}).Where("id = ?", user.ID).UpdateColumn("total_likes_received", total)
					if result.Error != nil {
						return result.Error
					}
					if result.RowsAffected != 1 {
						return errors.New("用户快照写入数量异常")
					}
				}
			}
		}
		return nil
	}, &sql.TxOptions{Isolation: sql.LevelRepeatableRead, ReadOnly: !apply})
	if err != nil {
		return snapshotReport{}, err
	}
	report.Changed = len(report.Changes)
	return report, nil
}

func run(ctx context.Context, args []string, getenv func(string) string, output io.Writer) error {
	flags := flag.NewFlagSet("backfill_total_likes_received", flag.ContinueOnError)
	flags.SetOutput(output)
	apply := flags.Bool("apply", false, "在停写窗口显式写入；默认只预览")
	driver := flags.String("driver", "postgres", "postgres 或 sqlite")
	dsnEnv := flags.String("dsn-env", "RECEIVED_LIKES_BACKFILL_DSN", "专用数据库连接环境变量名称")
	timeout := flags.Duration("timeout", 5*time.Minute, "整次操作超时（含锁等待）")
	if err := flags.Parse(args); err != nil {
		return err
	}
	if flags.NArg() != 0 || *timeout <= 0 {
		return errors.New("不接受位置参数，timeout 必须为正数")
	}
	dsn := strings.TrimSpace(getenv(*dsnEnv))
	if dsn == "" {
		return fmt.Errorf("请显式设置 %s；不会读取应用配置或 .env", *dsnEnv)
	}
	var dialector gorm.Dialector
	switch *driver {
	case "postgres":
		dialector = postgres.Open(dsn)
	case "sqlite":
		dialector = sqlite.Open(dsn)
	default:
		return errors.New("driver 必须为 postgres 或 sqlite")
	}
	ctx, cancel := context.WithTimeout(ctx, *timeout)
	defer cancel()
	// 不打印连接错误原文，防止驱动错误带出 DSN 中的凭据。
	db, err := gorm.Open(dialector, &gorm.Config{Logger: logger.Discard, DisableAutomaticPing: true})
	if err != nil {
		return errors.New("数据库连接配置无效")
	}
	pool, err := db.DB()
	if err != nil {
		return errors.New("无法获取数据库连接")
	}
	defer pool.Close()
	if err := pool.PingContext(ctx); err != nil {
		return errors.New("数据库连接失败，请检查专用环境变量和超时")
	}
	report, err := rebuildSnapshot(ctx, db, *apply)
	if err != nil {
		return fmt.Errorf("快照校准失败，事务未提交: %w", err)
	}
	return json.NewEncoder(output).Encode(report)
}

func main() {
	if err := run(context.Background(), os.Args[1:], os.Getenv, os.Stdout); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
