package main

import (
	"context"
	"encoding/json"
	"flag"
	"log"
	"os"
	"strings"

	"gorm.io/driver/postgres"
	"gorm.io/gorm"

	"shenliyuan/internal/config"
	"shenliyuan/internal/dto"
	"shenliyuan/internal/models"
	"shenliyuan/internal/services"
)

func main() {
	inputPath := flag.String("input", "", "Path to merged catalog JSON")
	backupConfirmed := flag.Bool("backup-confirmed", false, "Confirm DB backup has been completed")
	actorUserID := flag.Uint("actor-user-id", 1, "Admin user ID for audit log")
	flag.Parse()

	if *inputPath == "" {
		log.Fatal("Must provide -input <path to catalog json>")
	}
	if !*backupConfirmed {
		log.Fatal("Must provide -backup-confirmed")
	}

	content, err := os.ReadFile(*inputPath)
	if err != nil {
		log.Fatalf("Read file %s failed: %v", *inputPath, err)
	}

	var document dto.CompetitionCatalogDocument
	if err := json.Unmarshal(content, &document); err != nil {
		log.Fatalf("Unmarshal JSON failed: %v", err)
	}

	// 重新按照 Go 标准算法复算所有记录摘要与包摘要，彻底消除跨语言序列化边缘差异
	recordHashes := make(map[string]string, len(document.Items))
	for i := range document.Items {
		h, err := services.ComputeCompetitionRecordHash(document.Items[i])
		if err != nil {
			log.Fatalf("Compute record hash for %s failed: %v", document.Items[i].CompetitionID, err)
		}
		document.Items[i].RecordHash = h
		recordHashes[document.Items[i].CompetitionID] = h
	}
	pkgHash, err := services.ComputeCompetitionPackageHash(document, recordHashes)
	if err != nil {
		log.Fatalf("Compute package hash failed: %v", err)
	}
	document.PackageHash = pkgHash

	cfg := config.Load()
	if strings.TrimSpace(cfg.DSN) == "" {
		log.Fatal("DSN is empty")
	}
	db, err := gorm.Open(postgres.Open(cfg.DSN), &gorm.Config{})
	if err != nil {
		log.Fatalf("Connect DB failed: %v", err)
	}

	ctx := context.Background()
	importer := services.NewCompetitionCatalogImporter(db)

	log.Printf("Validating catalog document: dataset_version=%s items=%d", document.DatasetVersion, len(document.Items))
	validation := importer.Validate(document)
	if validation.Status != "passed" {
		log.Fatalf("Catalog validation failed: %+v", validation)
	}
	log.Printf("Validation passed! ComputedPackageHash=%s", validation.ComputedPackageHash)

	log.Printf("Importing catalog package...")
	pkg, val, err := importer.Import(ctx, document, *actorUserID)
	if err != nil {
		log.Fatalf("Import failed: %v (val: %+v)", err, val)
	}
	log.Printf("Imported package ID=%d dataset_version=%s revision=%d status=%s", pkg.ID, pkg.DatasetVersion, pkg.Revision, pkg.PublishStatus)

	log.Printf("Activating package ID=%d...", pkg.ID)
	if err := importer.Activate(ctx, pkg.ID, *actorUserID); err != nil {
		log.Fatalf("Activate failed: %v", err)
	}
	log.Printf("SUCCESS! Package ID=%d is now ACTIVE!", pkg.ID)

	var activeCount int64
	db.Model(&models.CompetitionEvent{}).Where("catalog_package_id = ?", pkg.ID).Count(&activeCount)
	log.Printf("Total events linked to active package: %d", activeCount)

	var regStartCount int64
	db.Model(&models.CompetitionEvent{}).Where("catalog_package_id = ? AND registration_start IS NOT NULL", pkg.ID).Count(&regStartCount)
	log.Printf("Total events with registration_start: %d", regStartCount)
}
