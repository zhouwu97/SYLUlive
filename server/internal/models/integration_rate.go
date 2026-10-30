package models

import "time"

type IntegrationRateBucket struct {
	Key       string    `gorm:"size:64;primaryKey"`
	Count     int       `gorm:"not null"`
	ExpiresAt time.Time `gorm:"index;not null"`
}
