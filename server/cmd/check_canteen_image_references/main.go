// 部署前预检：使用 DSN 环境变量连接 PostgreSQL，只输出损坏记录的表名和 ID。
package main

import (
	"database/sql"
	"encoding/json"
	"fmt"
	"gorm.io/driver/postgres"
	"gorm.io/gorm"
	"gorm.io/gorm/logger"
	"os"
	"shenliyuan/internal/services"
)

func main() {
	dsn := os.Getenv("DSN")
	if dsn == "" {
		fmt.Fprintln(os.Stderr, "请设置 DSN 环境变量")
		os.Exit(1)
	}
	db, err := gorm.Open(postgres.Open(dsn), &gorm.Config{Logger: logger.Default.LogMode(logger.Silent)})
	if err != nil {
		fmt.Fprintln(os.Stderr, "数据库连接失败")
		os.Exit(1)
	}
	var invalid []services.InvalidCanteenImageReference
	err = db.Transaction(func(tx *gorm.DB) error {
		var scanErr error
		invalid, scanErr = services.CheckCanteenImageReferences(tx)
		return scanErr
	}, &sql.TxOptions{ReadOnly: true})
	if err != nil {
		fmt.Fprintln(os.Stderr, "历史图片引用预检失败")
		os.Exit(1)
	}
	if err := json.NewEncoder(os.Stdout).Encode(invalid); err != nil {
		os.Exit(1)
	}
	if len(invalid) > 0 {
		os.Exit(2)
	}
}
