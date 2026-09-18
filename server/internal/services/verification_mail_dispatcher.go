package services

import (
	"errors"
	"time"
)

var ErrVerificationMailQueueFull = errors.New("验证码邮件队列已满")
var ErrVerificationMailTimeout = errors.New("验证码邮件发送超时")

const verificationMailSendTimeout = 10 * time.Second

type verificationMailJob struct {
	mailer    VerificationMailer
	email     string
	purpose   string
	code      string
	onFailure func()
	onSuccess func()
}

// VerificationMailDispatcher 将 SMTP 从 HTTP handler 中移出，避免慢 SMTP 长时间占用请求 goroutine。
type VerificationMailDispatcher struct {
	jobs        chan verificationMailJob
	sendTimeout time.Duration
}

func NewVerificationMailDispatcher(mailer VerificationMailer, queueSize, workers int) *VerificationMailDispatcher {
	return newVerificationMailDispatcher(mailer, queueSize, workers, verificationMailSendTimeout)
}

func newVerificationMailDispatcher(mailer VerificationMailer, queueSize, workers int, sendTimeout time.Duration) *VerificationMailDispatcher {
	if queueSize <= 0 {
		queueSize = 256
	}
	if workers <= 0 {
		workers = 3
	}
	if sendTimeout <= 0 {
		sendTimeout = verificationMailSendTimeout
	}
	dispatcher := &VerificationMailDispatcher{jobs: make(chan verificationMailJob, queueSize), sendTimeout: sendTimeout}
	for i := 0; i < workers; i++ {
		go dispatcher.worker(mailer)
	}
	return dispatcher
}

func (d *VerificationMailDispatcher) worker(mailer VerificationMailer) {
	for job := range d.jobs {
		if err := sendVerificationMailWithTimeout(mailer, job.email, job.purpose, job.code, d.sendTimeout); err != nil {
			if job.onFailure != nil {
				job.onFailure()
			}
		} else if job.onSuccess != nil {
			job.onSuccess()
		}
	}
}

// sendVerificationMailWithTimeout 把没有上下文接口的旧 Mailer 也纳入硬超时保护，
// 防止 SMTP 卡住时长期占满所有投递 worker。
func sendVerificationMailWithTimeout(mailer VerificationMailer, email, purpose, code string, timeout time.Duration) error {
	result := make(chan error, 1)
	go func() { result <- mailer.SendVerificationCode(email, purpose, code) }()
	timer := time.NewTimer(timeout)
	defer timer.Stop()
	select {
	case err := <-result:
		return err
	case <-timer.C:
		return ErrVerificationMailTimeout
	}
}

func (d *VerificationMailDispatcher) Dispatch(email, purpose, code string, onFailure, onSuccess func()) error {
	if d == nil {
		return ErrVerificationMailQueueFull
	}
	select {
	case d.jobs <- verificationMailJob{email: email, purpose: purpose, code: code, onFailure: onFailure, onSuccess: onSuccess}:
		return nil
	default:
		return ErrVerificationMailQueueFull
	}
}
