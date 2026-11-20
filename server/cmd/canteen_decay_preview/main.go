// 上线前预览：使用 DSN 环境变量以只读事务连接 PostgreSQL，对比开启评分时间衰减前后的
// 食堂综合排名，按新排名输出一张表。不写入任何数据。
package main

import (
	"database/sql"
	"fmt"
	"os"
	"text/tabwriter"

	"shenliyuan/internal/handlers"

	"gorm.io/driver/postgres"
	"gorm.io/gorm"
	"gorm.io/gorm/logger"
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
	var rows []handlers.CanteenDecayPreviewRow
	err = db.Transaction(func(tx *gorm.DB) error {
		var previewErr error
		rows, previewErr = handlers.PreviewCanteenDecayRanking(tx)
		return previewErr
	}, &sql.TxOptions{ReadOnly: true})
	if err != nil {
		fmt.Fprintln(os.Stderr, "排名预览失败：", err)
		os.Exit(1)
	}
	w := tabwriter.NewWriter(os.Stdout, 0, 2, 2, ' ', 0)
	fmt.Fprintln(w, "新排名\t旧排名\t变化\t店名\t评价人数\t新综合分\t旧综合分")
	for _, row := range rows {
		fmt.Fprintf(w, "%d\t%d\t%+d\t%s\t%d\t%.1f\t%.1f\n",
			row.RankAfter, row.RankBefore, row.RankBefore-row.RankAfter, row.Name,
			row.RatingCount, row.ScoreAfter, row.ScoreBefore)
	}
	_ = w.Flush()
}
