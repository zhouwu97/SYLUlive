package services

import (
	"context"
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
	onFailure func(error)
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
		ctx, cancel := context.WithTimeout(context.Background(), d.sendTimeout)
		err := normalizeVerificationMailError(ctx, mailer.SendVerificationCode(ctx, job.email, job.purpose, job.code))
		cancel()
		if err != nil {
			if job.onFailure != nil {
				job.onFailure(err)
			}
		} else if job.onSuccess != nil {
			job.onSuccess()
		}
	}
}

func (d *VerificationMailDispatcher) Dispatch(email, purpose, code string, onFailure func(error), onSuccess func()) error {
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
