package utils

import (
	"errors"
	"github.com/jackc/pgx/v5/pgconn"
)

// IsPostgresUniqueViolation 判断是否为 PostgreSQL 唯一约束冲突 (23505)
func IsPostgresUniqueViolation(err error) bool {
	var pgErr *pgconn.PgError
	return errors.As(err, &pgErr) && pgErr.Code == "23505"
}

// IsPostgresRetryableTxError 判断是否为 PostgreSQL 可重试的事务冲突：
// 40P01 死锁、40001 序列化失败、40P02 事务回滚。这类错误代表并发竞争，
// 而非业务逻辑错误，调用方应转换为稳定冲突码让客户端重试。
func IsPostgresRetryableTxError(err error) bool {
	var pgErr *pgconn.PgError
	if !errors.As(err, &pgErr) {
		return false
	}
	switch pgErr.Code {
	case "40P01", "40001", "40P02":
		return true
	default:
		return false
	}
}
