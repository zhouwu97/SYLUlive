package main

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"strings"
)

const agentQualityGateSchemaVersion = "campus-agent-quality-gate/v1"

// agentQualityInspection 是知识版本发布前的 A3 门禁摘要，不复制评测原文。
type agentQualityInspection struct {
	Status           string `json:"status"`
	EvidenceType     string `json:"evidence_type,omitempty"`
	KnowledgeVersion string `json:"knowledge_version,omitempty"`
	ReportSHA256     string `json:"report_sha256,omitempty"`
	Error            string `json:"error,omitempty"`
}

type agentQualityReport struct {
	SchemaVersion     string            `json:"schema_version"`
	EvidenceType      string            `json:"evidence_type"`
	KnowledgeVersion  string            `json:"knowledge_version"`
	Blocked           bool              `json:"blocked"`
	PublishDecision   string            `json:"publish_decision"`
	RolloutDecision   string            `json:"rollout_decision"`
	Gates             map[string]string `json:"gates"`
	RequestsPerformed int               `json:"requests_performed"`
	WritesPerformed   bool              `json:"writes_performed"`
}

func inspectAgentQualityReport(path, expectedVersion string, requireRuntimeEvidence bool) (agentQualityInspection, error) {
	encoded, err := os.ReadFile(path)
	if err != nil {
		return agentQualityInspection{Status: "failed", Error: err.Error()}, err
	}
	var report agentQualityReport
	if err := json.Unmarshal(encoded, &report); err != nil {
		return agentQualityInspection{Status: "failed", Error: "质量报告不是有效 JSON"}, err
	}
	if report.SchemaVersion != agentQualityGateSchemaVersion {
		return agentQualityInspection{Status: "failed", Error: "质量报告 schema 不匹配"}, fmt.Errorf("agent quality schema mismatch")
	}
	if report.EvidenceType != "fixture" && report.EvidenceType != "staging" && report.EvidenceType != "online" {
		return agentQualityInspection{Status: "failed", Error: "质量报告 evidence_type 无效"}, fmt.Errorf("agent quality evidence type invalid")
	}
	if requireRuntimeEvidence && report.EvidenceType == "fixture" {
		return agentQualityInspection{Status: "failed", EvidenceType: report.EvidenceType, Error: "fixture 证据不能授权知识版本发布"}, fmt.Errorf("fixture quality evidence cannot authorize release")
	}
	if strings.TrimSpace(expectedVersion) == "" || report.KnowledgeVersion != expectedVersion {
		return agentQualityInspection{Status: "failed", EvidenceType: report.EvidenceType, KnowledgeVersion: report.KnowledgeVersion, Error: "质量报告知识版本与发布清单不一致"}, fmt.Errorf("agent quality knowledge version mismatch")
	}
	if report.Blocked || report.PublishDecision == "blocked" || report.RolloutDecision == "blocked" {
		return agentQualityInspection{Status: "blocked", EvidenceType: report.EvidenceType, KnowledgeVersion: report.KnowledgeVersion, Error: "A3 质量门禁已阻断"}, fmt.Errorf("agent quality gate blocked")
	}
	if len(report.Gates) == 0 {
		return agentQualityInspection{Status: "failed", EvidenceType: report.EvidenceType, KnowledgeVersion: report.KnowledgeVersion, Error: "质量报告缺少 gates"}, fmt.Errorf("agent quality gates missing")
	}
	for name, result := range report.Gates {
		if result != "pass" {
			return agentQualityInspection{Status: "blocked", EvidenceType: report.EvidenceType, KnowledgeVersion: report.KnowledgeVersion, Error: "质量门禁未全部通过：" + name}, fmt.Errorf("agent quality gate %s failed", name)
		}
	}
	if report.RequestsPerformed != 0 || report.WritesPerformed {
		return agentQualityInspection{Status: "failed", EvidenceType: report.EvidenceType, KnowledgeVersion: report.KnowledgeVersion, Error: "质量报告声称发生了写入或请求"}, fmt.Errorf("agent quality report has side effects")
	}
	digest := sha256.Sum256(encoded)
	return agentQualityInspection{
		Status: "passed", EvidenceType: report.EvidenceType, KnowledgeVersion: report.KnowledgeVersion,
		ReportSHA256: hex.EncodeToString(digest[:]),
	}, nil
}
