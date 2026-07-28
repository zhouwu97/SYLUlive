package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strconv"
	"strings"

	"shenliyuan/internal/models"
)

type knowledgeAPI struct {
	baseURL string
	token   string
	client  *http.Client
}

type knowledgeReadResponse struct {
	Document models.AIKnowledgeDocument `json:"document"`
	Content  string                     `json:"content"`
}

func newKnowledgeAPI(baseURL, token string, client *http.Client) *knowledgeAPI {
	if client == nil {
		client = &http.Client{}
	}
	return &knowledgeAPI{baseURL: strings.TrimRight(strings.TrimSpace(baseURL), "/"), token: strings.TrimSpace(token), client: client}
}

func fetchKnowledgeInventory(ctx context.Context, client *http.Client, baseURL, token string) ([]models.AIKnowledgeDocument, error) {
	api := newKnowledgeAPI(baseURL, token, client)
	documents := make([]models.AIKnowledgeDocument, 0)
	var beforeID uint
	for page := 0; page < 1000; page++ {
		var response struct {
			Documents    []models.AIKnowledgeDocument `json:"documents"`
			NextBeforeID uint                         `json:"next_before_id"`
		}
		path := "/api/admin/ai/knowledge?limit=100"
		if beforeID != 0 {
			path += "&before_id=" + strconv.FormatUint(uint64(beforeID), 10)
		}
		if err := api.request(ctx, http.MethodGet, path, nil, &response); err != nil {
			return nil, fmt.Errorf("读取知识库清单失败：%w", err)
		}
		documents = append(documents, response.Documents...)
		if response.NextBeforeID == 0 {
			return documents, nil
		}
		if response.NextBeforeID >= beforeID && beforeID != 0 {
			return nil, fmt.Errorf("知识库清单分页游标未前进")
		}
		beforeID = response.NextBeforeID
	}
	return nil, fmt.Errorf("知识库清单超过分页安全上限")
}

func (api *knowledgeAPI) importDocument(ctx context.Context, document releaseDocument) (models.AIKnowledgeDocument, error) {
	var response struct {
		Document models.AIKnowledgeDocument `json:"document"`
	}
	if err := api.request(ctx, http.MethodPost, "/api/admin/ai/knowledge/import", document, &response); err != nil {
		return models.AIKnowledgeDocument{}, err
	}
	return response.Document, nil
}

func (api *knowledgeAPI) readDocument(ctx context.Context, id uint) (models.AIKnowledgeDocument, error) {
	var response knowledgeReadResponse
	if err := api.request(ctx, http.MethodGet, "/api/admin/ai/knowledge/"+strconv.FormatUint(uint64(id), 10), nil, &response); err != nil {
		return models.AIKnowledgeDocument{}, err
	}
	response.Document.Content = response.Content
	return response.Document, nil
}

func (api *knowledgeAPI) action(ctx context.Context, action string, documentID, replacementID uint, output any) error {
	var body any
	if action == "supersede" {
		body = map[string]uint{"replacement_document_id": replacementID}
	}
	path := "/api/admin/ai/knowledge/" + strconv.FormatUint(uint64(documentID), 10) + "/" + action
	return api.request(ctx, http.MethodPost, path, body, output)
}

func (api *knowledgeAPI) release(ctx context.Context, version string, items []knowledgeReleaseAPIItem, output any) error {
	payload := map[string]any{"version": version, "items": items}
	return api.request(ctx, http.MethodPost, "/api/admin/ai/knowledge/release", payload, output)
}

func (api *knowledgeAPI) rollback(ctx context.Context, version string, items []knowledgeRollbackAPIItem, output any) error {
	payload := map[string]any{"version": version, "items": items}
	return api.request(ctx, http.MethodPost, "/api/admin/ai/knowledge/rollback", payload, output)
}

func (api *knowledgeAPI) request(ctx context.Context, method, path string, body, output any) error {
	var reader io.Reader
	if body != nil {
		encoded, err := json.Marshal(body)
		if err != nil {
			return err
		}
		reader = bytes.NewReader(encoded)
	}
	request, err := http.NewRequestWithContext(ctx, method, api.baseURL+path, reader)
	if err != nil {
		return err
	}
	request.Header.Set("Authorization", "Bearer "+api.token)
	if body != nil {
		request.Header.Set("Content-Type", "application/json")
	}
	response, err := api.client.Do(request)
	if err != nil {
		return err
	}
	defer response.Body.Close()
	responseBody, err := io.ReadAll(io.LimitReader(response.Body, (2<<20)+1))
	if err != nil {
		return err
	}
	if len(responseBody) > 2<<20 {
		return fmt.Errorf("API 响应超过大小限制")
	}
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		message := strings.TrimSpace(string(responseBody))
		if len(message) > 500 {
			message = message[:500]
		}
		return fmt.Errorf("API 返回 HTTP %d：%s", response.StatusCode, message)
	}
	if output == nil || len(bytes.TrimSpace(responseBody)) == 0 {
		return nil
	}
	if err := json.Unmarshal(responseBody, output); err != nil {
		return fmt.Errorf("API 响应格式无效：%w", err)
	}
	return nil
}
