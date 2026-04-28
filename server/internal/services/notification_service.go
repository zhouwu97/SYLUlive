package services

type NotificationService struct{}

func NewNotificationService() *NotificationService {
	return &NotificationService{}
}

func (s *NotificationService) Notify(userID uint, title, content string) error {
	return nil
}