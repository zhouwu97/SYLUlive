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
