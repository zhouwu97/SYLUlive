package services

import "errors"

var ErrVerificationMailQueueFull = errors.New("验证码邮件队列已满")

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
	jobs chan verificationMailJob
}

func NewVerificationMailDispatcher(mailer VerificationMailer, queueSize, workers int) *VerificationMailDispatcher {
	if queueSize <= 0 {
		queueSize = 256
	}
	if workers <= 0 {
		workers = 3
	}
	dispatcher := &VerificationMailDispatcher{jobs: make(chan verificationMailJob, queueSize)}
	for i := 0; i < workers; i++ {
		go dispatcher.worker(mailer)
	}
	return dispatcher
}

func (d *VerificationMailDispatcher) worker(mailer VerificationMailer) {
	for job := range d.jobs {
		if err := mailer.SendVerificationCode(job.email, job.purpose, job.code); err != nil {
			if job.onFailure != nil {
				job.onFailure()
			}
		} else if job.onSuccess != nil {
			job.onSuccess()
		}
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
