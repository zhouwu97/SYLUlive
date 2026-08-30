package services

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"sync"
	"time"

	"gorm.io/gorm"

	"shenliyuan/internal/academic"
	"shenliyuan/internal/clients"
)

const (
	defaultEduFetchTimeout = 20 * time.Second
	defaultEduFetchWorkers = 3
)

// EduContextFetcher 是 Python 教务聚合客户端的最小接口，便于独立测试编排规则。
type EduContextFetcher interface {
	FetchContextBundle(context.Context, uint, []clients.EduContextDataset) (clients.EduContextBundle, error)
}

// EduFetchRequest 表示一个可快照化的远程教务数据集请求。
type EduFetchRequest struct {
	Dataset      academic.DatasetType
	Year         string
	Semester     int
	CurrentTerm  bool
	ForceRefresh bool
	RunID        string
}

// EduFetchBundleRequest 允许校园 Agent 在同一个 Run 内请求多个数据集。
type EduFetchBundleRequest struct {
	UserID   uint
	RunID    string
	Requests []EduFetchRequest
}

type eduFetchFlight struct {
	done    chan struct{}
	result  academic.ContextResult
	cancel  context.CancelFunc
	waiters int
}

// EduFetchOrchestrator 统一处理缓存优先、远程抓取去重、并发上限和旧快照回退。
type EduFetchOrchestrator struct {
	db        *gorm.DB
	client    EduContextFetcher
	snapshots *AcademicSnapshotService
	now       func() time.Time
	timeout   time.Duration
	workers   chan struct{}

	mu       sync.Mutex
	inflight map[string]*eduFetchFlight
}

// EduFetchOrchestratorOptions 用于注入时钟、超时和并发上限。
type EduFetchOrchestratorOptions struct {
	Now         func() time.Time
	Timeout     time.Duration
	MaxInflight int
}

func NewEduFetchOrchestrator(db *gorm.DB, client EduContextFetcher, snapshots *AcademicSnapshotService, options EduFetchOrchestratorOptions) *EduFetchOrchestrator {
	now := options.Now
	if now == nil {
		now = time.Now
	}
	timeout := options.Timeout
	if timeout <= 0 {
		timeout = defaultEduFetchTimeout
	}
	maxInflight := options.MaxInflight
	if maxInflight <= 0 {
		maxInflight = defaultEduFetchWorkers
	}
	return &EduFetchOrchestrator{
		db: db, client: client, snapshots: snapshots, now: now, timeout: timeout,
		workers: make(chan struct{}, maxInflight), inflight: make(map[string]*eduFetchFlight),
	}
}

// Fetch 缓存优先读取单个数据集；显式刷新时才跳过有效快照。
func (orchestrator *EduFetchOrchestrator) Fetch(ctx context.Context, userID uint, request EduFetchRequest) (academic.ContextResult, error) {
	if orchestrator == nil || orchestrator.client == nil || orchestrator.snapshots == nil || userID == 0 {
		return academic.ContextResult{}, errors.New("教务拉取编排器未配置")
	}
	dataset, scopeKey, err := normalizeEduFetchRequest(request)
	if err != nil {
		return academic.ContextResult{}, err
	}
	generation, err := orchestrator.snapshots.CurrentCredentialGeneration(ctx, userID)
	if err != nil {
		return orchestrator.authorizationResult(err), nil
	}
	lookup, lookupErr := orchestrator.snapshots.Lookup(ctx, userID, request.Dataset, scopeKey, generation)
	if lookupErr != nil && !errors.Is(lookupErr, ErrAcademicSnapshotCorrupted) {
		return academic.ContextResult{}, lookupErr
	}
	if lookup.Found && !lookup.Corrupted && !lookup.Result.IsStale && !request.ForceRefresh {
		return lookup.Result, nil
	}

	flightKey := fmt.Sprintf("%d:%d:%s:%s", userID, generation, dataset.Type, scopeKey)
	flight, leader, flightCtx := orchestrator.joinFlight(flightKey)
	if leader {
		go func() {
			result := orchestrator.fetchRemote(flightCtx, userID, generation, request, dataset, scopeKey, lookup)
			orchestrator.finishFlight(flightKey, flight, result)
		}()
	}

	select {
	case <-ctx.Done():
		orchestrator.leaveFlight(flightKey, flight)
		return academic.ContextResult{}, ctx.Err()
	case <-flight.done:
		return flight.result, nil
	}
}

// FetchBundle 逐项复用同一套飞行任务；同一个 AI Run 中的重复数据集只会执行一次远程抓取。
func (orchestrator *EduFetchOrchestrator) FetchBundle(ctx context.Context, request EduFetchBundleRequest) (map[academic.DatasetType]academic.ContextResult, error) {
	if request.UserID == 0 || len(request.Requests) == 0 {
		return nil, errors.New("教务批量拉取参数无效")
	}
	results := make(map[academic.DatasetType]academic.ContextResult, len(request.Requests))
	seen := make(map[string]struct{}, len(request.Requests))
	for _, item := range request.Requests {
		item.RunID = request.RunID
		dataset, scopeKey, err := normalizeEduFetchRequest(item)
		if err != nil {
			return nil, err
		}
		key := string(dataset.Type) + ":" + scopeKey
		if _, duplicated := seen[key]; duplicated {
			continue
		}
		seen[key] = struct{}{}
		result, err := orchestrator.Fetch(ctx, request.UserID, item)
		if err != nil {
			return nil, err
		}
		results[item.Dataset] = result
	}
	return results, nil
}

func (orchestrator *EduFetchOrchestrator) fetchRemote(ctx context.Context, userID, generation uint, request EduFetchRequest, dataset clients.EduContextDataset, scopeKey string, staleSnapshot AcademicSnapshotLookup) academic.ContextResult {
	select {
	case orchestrator.workers <- struct{}{}:
		defer func() { <-orchestrator.workers }()
	case <-ctx.Done():
		return orchestrator.remoteFailureResult(ctx.Err(), request.Dataset, staleSnapshot)
	}
	bundle, err := orchestrator.client.FetchContextBundle(ctx, userID, []clients.EduContextDataset{dataset})
	if err != nil {
		return orchestrator.remoteFailureResult(err, request.Dataset, staleSnapshot)
	}
	item, found := bundle.Results[dataset.Key()]
	if !found {
		return orchestrator.remoteFailureResult(errors.New("教务聚合结果缺少请求数据集"), request.Dataset, staleSnapshot)
	}
	if item.Status != "success" || !json.Valid(item.Data) {
		return orchestrator.remoteItemFailureResult(item, request.Dataset, staleSnapshot)
	}
	now := orchestrator.now()
	isPartial := bundle.Partial
	if err := orchestrator.snapshots.StoreRemote(ctx, AcademicSnapshotInput{
		UserID: userID, Dataset: request.Dataset, ScopeKey: scopeKey, SchemaVersion: 1,
		Source: academic.DataSourceRemoteEduFetch, Payload: item.Data, FetchedAt: now,
		ExpiresAt: orchestrator.snapshotExpiry(request, now), IsPartial: isPartial, CredentialGeneration: generation,
	}); err != nil {
		if errors.Is(err, ErrSnapshotCredentialGenerationChanged) {
			return orchestrator.authorizationResult(err)
		}
		return orchestrator.remoteFailureResult(err, request.Dataset, staleSnapshot)
	}
	expiresAt := orchestrator.snapshotExpiry(request, now)
	warnings := make([]string, 0, 1)
	status := academic.DataStatusAvailable
	if isPartial {
		status = academic.DataStatusPartial
		warnings = append(warnings, "本次教务聚合仅部分完成")
	}
	return academic.ContextResult{
		Data:      append(json.RawMessage(nil), item.Data...),
		Status:    status,
		Source:    academic.DataSourceRemoteEduFetch,
		FetchedAt: &now,
		ExpiresAt: &expiresAt,
		IsPartial: isPartial,
		Warnings:  warnings,
		Evidence: []academic.Evidence{{
			Source: academic.DataSourceRemoteEduFetch, Dataset: request.Dataset, ScopeKey: scopeKey,
			FetchedAt: &now, ExpiresAt: &expiresAt,
		}},
	}
}

func (orchestrator *EduFetchOrchestrator) joinFlight(key string) (*eduFetchFlight, bool, context.Context) {
	orchestrator.mu.Lock()
	defer orchestrator.mu.Unlock()
	if existing := orchestrator.inflight[key]; existing != nil {
		existing.waiters++
		return existing, false, nil
	}
	flightCtx, cancel := context.WithTimeout(context.Background(), orchestrator.timeout)
	flight := &eduFetchFlight{
		done:    make(chan struct{}),
		cancel:  cancel,
		waiters: 1,
	}
	orchestrator.inflight[key] = flight
	return flight, true, flightCtx
}

func (orchestrator *EduFetchOrchestrator) leaveFlight(key string, flight *eduFetchFlight) {
	orchestrator.mu.Lock()
	defer orchestrator.mu.Unlock()
	flight.waiters--
	if flight.waiters <= 0 {
		flight.cancel()
	}
}

func (orchestrator *EduFetchOrchestrator) finishFlight(key string, flight *eduFetchFlight, result academic.ContextResult) {
	orchestrator.mu.Lock()
	flight.result = result
	flight.cancel()
	delete(orchestrator.inflight, key)
	close(flight.done)
	orchestrator.mu.Unlock()
}

func (orchestrator *EduFetchOrchestrator) remoteFailureResult(err error, dataset academic.DatasetType, staleSnapshot AcademicSnapshotLookup) academic.ContextResult {
	if staleSnapshot.Found && !staleSnapshot.Corrupted && len(staleSnapshot.Result.Data) > 0 {
		result := staleSnapshot.Result
		result.Status = academic.DataStatusStale
		result.IsStale = true
		result.Warnings = append(result.Warnings, "远程教务更新失败，继续使用旧快照")
		return result
	}
	return failedEduContextResult(dataset, "edu_fetch_failed", "教务数据暂时无法更新")
}

func (orchestrator *EduFetchOrchestrator) remoteItemFailureResult(item clients.EduContextItem, dataset academic.DatasetType, staleSnapshot AcademicSnapshotLookup) academic.ContextResult {
	if isEduAuthorizationFailure(item.ErrorCode) {
		return orchestrator.authorizationResult(ErrSnapshotCredentialGenerationChanged)
	}
	if staleSnapshot.Found && !staleSnapshot.Corrupted && len(staleSnapshot.Result.Data) > 0 {
		result := staleSnapshot.Result
		result.Status = academic.DataStatusStale
		result.IsStale = true
		result.Warnings = append(result.Warnings, "远程教务更新未完成，继续使用旧快照")
		return result
	}
	code := strings.TrimSpace(item.ErrorCode)
	if code == "" {
		code = "edu_fetch_failed"
	}
	message := strings.TrimSpace(item.Message)
	if message == "" {
		message = "教务数据暂时无法更新"
	}
	return failedEduContextResult(dataset, code, message)
}

func isEduAuthorizationFailure(code string) bool {
	switch strings.ToUpper(strings.TrimSpace(code)) {
	case "EDU_AUTHORIZATION_REVOKED", "EDU_SESSION_LOGGED_OUT", "EDU_SESSION_EXPIRED", "EDU_LOGIN_FAILED", "EDU_INVALID_CREDENTIALS":
		return true
	default:
		return false
	}
}

func (orchestrator *EduFetchOrchestrator) authorizationResult(err error) academic.ContextResult {
	if errors.Is(err, gorm.ErrRecordNotFound) {
		return failedEduContextResult("", "user_not_found", "用户不存在")
	}
	return academic.ContextResult{
		Data:     json.RawMessage(`{"error_code":"edu_authorization_required"}`),
		Status:   academic.DataStatusPermissionRequired,
		Source:   academic.DataSourceNone,
		Warnings: []string{"教务授权已撤销、过期或已更新，请重新授权后再试"},
		Evidence: make([]academic.Evidence, 0),
	}
}

func failedEduContextResult(dataset academic.DatasetType, code, message string) academic.ContextResult {
	payload, _ := json.Marshal(map[string]string{"error_code": code})
	return academic.ContextResult{
		Data: payload, Status: academic.DataStatusFailed, Source: academic.DataSourceNone,
		Warnings: []string{message}, Evidence: make([]academic.Evidence, 0),
	}
}

func (orchestrator *EduFetchOrchestrator) snapshotExpiry(request EduFetchRequest, fetchedAt time.Time) time.Time {
	switch request.Dataset {
	case academic.DatasetSchedule:
		if request.CurrentTerm {
			return fetchedAt.Add(12 * time.Hour)
		}
		return fetchedAt.Add(180 * 24 * time.Hour)
	case academic.DatasetGrades:
		return fetchedAt.Add(24 * time.Hour)
	case academic.DatasetAcademicSituation, academic.DatasetCreditRequirements:
		return fetchedAt.Add(12 * time.Hour)
	default:
		return fetchedAt.Add(12 * time.Hour)
	}
}

func normalizeEduFetchRequest(request EduFetchRequest) (clients.EduContextDataset, string, error) {
	dataset := clients.EduContextDataset{Type: request.Dataset, Year: strings.TrimSpace(request.Year), Semester: request.Semester}
	if err := dataset.Validate(); err != nil {
		return clients.EduContextDataset{}, "", err
	}
	if dataset.Year == "" {
		return dataset, "default", nil
	}
	return dataset, fmt.Sprintf("%s:%d", dataset.Year, dataset.Semester), nil
}
