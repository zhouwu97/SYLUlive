package services

import (
	"encoding/json"
	"fmt"
	"strings"
	"time"
	"unicode"

	"shenliyuan/internal/models"

	"gorm.io/gorm"
	"gorm.io/gorm/clause"
)

const MaxPostTopics = 5

// TopicSchemaUnavailable 用于兼容尚未执行 Topic 迁移的旧实例。
func TopicSchemaUnavailable(err error) bool {
	if err == nil {
		return false
	}
	message := strings.ToLower(err.Error())
	return strings.Contains(message, "no such table") ||
		strings.Contains(message, "does not exist") ||
		strings.Contains(message, "undefined table")
}

// TopicSelection 是发帖请求中一个已有或自定义话题的内部表示。
type TopicSelection struct {
	ID   uint
	Name string
}

// TopicInputError 表示可直接返回给客户端的 Topic 请求错误。
type TopicInputError struct{ Message string }

func (e *TopicInputError) Error() string { return e.Message }

// NormalizeTopicName 将用户输入转换为 Topic 的唯一标准名称。
func NormalizeTopicName(raw string) (string, error) {
	value := strings.TrimSpace(raw)
	if value == "" {
		return "", &TopicInputError{Message: "话题不能为空"}
	}
	for _, r := range value {
		if r == '\n' || r == '\r' || r == '\t' || unicode.IsControl(r) {
			return "", &TopicInputError{Message: "话题不能包含换行或控制字符"}
		}
	}
	value = strings.TrimSpace(strings.TrimLeft(value, "#＃"))
	value = strings.Join(strings.Fields(value), " ")
	if value == "" {
		return "", &TopicInputError{Message: "话题不能为空"}
	}
	runes := []rune(value)
	if len(runes) > 20 {
		return "", &TopicInputError{Message: "话题最多 20 个字符"}
	}
	allPunctuation := true
	for _, r := range runes {
		if !unicode.IsPunct(r) && !unicode.IsSymbol(r) && !unicode.IsSpace(r) {
			allPunctuation = false
			break
		}
	}
	if allPunctuation {
		return "", &TopicInputError{Message: "话题不能只有标点符号"}
	}
	return value, nil
}

// ParseTopicSelections 解析 topics_json。provided=false 表示旧客户端未提交该字段。
func ParseTopicSelections(raw string, provided bool) ([]TopicSelection, error) {
	if !provided {
		return nil, nil
	}
	if strings.TrimSpace(raw) == "" {
		return []TopicSelection{}, nil
	}
	var items []map[string]json.RawMessage
	if err := json.Unmarshal([]byte(raw), &items); err != nil {
		return nil, &TopicInputError{Message: "话题格式无效"}
	}
	if len(items) > MaxPostTopics {
		return nil, &TopicInputError{Message: fmt.Sprintf("最多选择 %d 个话题", MaxPostTopics)}
	}
	selections := make([]TopicSelection, 0, len(items))
	seenIDs := make(map[uint]struct{})
	seenNames := make(map[string]struct{})
	for _, item := range items {
		idRaw, hasID := item["id"]
		nameRaw, hasName := item["name"]
		if hasID && hasName {
			return nil, &TopicInputError{Message: "已有话题不能同时提交名称"}
		}
		if hasID {
			var id uint
			if err := json.Unmarshal(idRaw, &id); err != nil || id == 0 {
				return nil, &TopicInputError{Message: "话题 ID 无效"}
			}
			if _, exists := seenIDs[id]; exists {
				return nil, &TopicInputError{Message: "不能重复选择同一话题"}
			}
			seenIDs[id] = struct{}{}
			selections = append(selections, TopicSelection{ID: id})
			continue
		}
		if hasName {
			var name string
			if err := json.Unmarshal(nameRaw, &name); err != nil {
				return nil, &TopicInputError{Message: "话题名称无效"}
			}
			normalized, err := NormalizeTopicName(name)
			if err != nil {
				return nil, err
			}
			if _, exists := seenNames[normalized]; exists {
				return nil, &TopicInputError{Message: "不能重复选择同一话题"}
			}
			seenNames[normalized] = struct{}{}
			selections = append(selections, TopicSelection{Name: normalized})
			continue
		}
		return nil, &TopicInputError{Message: "话题项必须包含 id 或 name"}
	}
	return selections, nil
}

// ResolveTopicSelections 在事务内安全地解析已有话题并创建自定义话题。
func ResolveTopicSelections(tx *gorm.DB, selections []TopicSelection) ([]models.Topic, error) {
	resolved := make([]models.Topic, 0, len(selections))
	for _, selection := range selections {
		if selection.ID > 0 {
			var topic models.Topic
			if err := tx.Where("id = ? AND status = ?", selection.ID, models.TopicStatusActive).First(&topic).Error; err != nil {
				if err == gorm.ErrRecordNotFound {
					return nil, &TopicInputError{Message: "所选话题不存在或已不可用"}
				}
				return nil, err
			}
			resolved = append(resolved, topic)
			continue
		}

		normalized, err := NormalizeTopicName(selection.Name)
		if err != nil {
			return nil, err
		}
		topic := models.Topic{
			Name:           normalized,
			NormalizedName: normalized,
			Status:         models.TopicStatusActive,
			CreatedAt:      time.Now(),
			UpdatedAt:      time.Now(),
		}
		if err := tx.Clauses(clause.OnConflict{
			Columns:   []clause.Column{{Name: "normalized_name"}},
			DoNothing: true,
		}).Create(&topic).Error; err != nil {
			return nil, err
		}
		if err := tx.Where("normalized_name = ?", normalized).First(&topic).Error; err != nil {
			return nil, err
		}
		if topic.Status != models.TopicStatusActive {
			return nil, &TopicInputError{Message: "该话题已不可用"}
		}
		resolved = append(resolved, topic)
	}
	return resolved, nil
}

// ReplacePostTopics 按 fieldProvided 区分“不修改”和“明确清空”，并维护 usage_count 缓存。
func ReplacePostTopics(tx *gorm.DB, postID uint, selections []TopicSelection, fieldProvided bool) error {
	if !fieldProvided {
		return nil
	}
	resolved, err := ResolveTopicSelections(tx, selections)
	if err != nil {
		return err
	}
	var existing []models.PostTopic
	if err := tx.Where("post_id = ?", postID).Find(&existing).Error; err != nil {
		return err
	}
	desired := make(map[uint]int, len(resolved))
	for index, topic := range resolved {
		desired[topic.ID] = index
	}
	existingByID := make(map[uint]models.PostTopic, len(existing))
	for _, link := range existing {
		existingByID[link.TopicID] = link
		if _, keep := desired[link.TopicID]; !keep {
			if err := tx.Delete(&link).Error; err != nil {
				return err
			}
			if err := tx.Model(&models.Topic{}).Where("id = ? AND usage_count > 0", link.TopicID).
				UpdateColumn("usage_count", gorm.Expr("usage_count - 1")).Error; err != nil {
				return err
			}
		}
	}
	for topicID, sortOrder := range desired {
		if link, exists := existingByID[topicID]; exists {
			if link.SortOrder != sortOrder {
				if err := tx.Model(&models.PostTopic{}).
					Where("post_id = ? AND topic_id = ?", postID, topicID).
					Update("sort_order", sortOrder).Error; err != nil {
					return err
				}
			}
			continue
		}
		if err := tx.Create(&models.PostTopic{PostID: postID, TopicID: topicID, SortOrder: sortOrder}).Error; err != nil {
			return err
		}
		if err := tx.Model(&models.Topic{}).Where("id = ?", topicID).
			UpdateColumn("usage_count", gorm.Expr("usage_count + 1")).Error; err != nil {
			return err
		}
	}
	return nil
}

type postTopicRow struct {
	PostID    uint   `gorm:"column:post_id"`
	ID        uint   `gorm:"column:id"`
	Name      string `gorm:"column:name"`
	SortOrder int    `gorm:"column:sort_order"`
}

// LoadTopicsForPosts 批量加载帖子话题，调用方只增加一次 SQL，不产生 N+1。
func LoadTopicsForPosts(tx *gorm.DB, posts []models.Post) error {
	if len(posts) == 0 {
		return nil
	}
	postIDs := make([]uint, 0, len(posts))
	byID := make(map[uint]int, len(posts))
	for index := range posts {
		posts[index].Topics = []models.TopicBrief{}
		postIDs = append(postIDs, posts[index].ID)
		byID[posts[index].ID] = index
	}
	var rows []postTopicRow
	if err := tx.Table("post_topics AS pt").
		Select("pt.post_id, t.id, t.name, pt.sort_order").
		Joins("JOIN topics AS t ON t.id = pt.topic_id").
		Where("pt.post_id IN ? AND t.status = ?", postIDs, models.TopicStatusActive).
		Order("pt.post_id ASC, pt.sort_order ASC, pt.topic_id ASC").
		Scan(&rows).Error; err != nil {
		return err
	}
	for _, row := range rows {
		if index, ok := byID[row.PostID]; ok {
			posts[index].Topics = append(posts[index].Topics, models.TopicBrief{ID: row.ID, Name: row.Name})
		}
	}
	return nil
}

// SearchTopics 返回可用于选择器的全局话题，section 只影响近期版块使用排序。
func SearchTopics(db *gorm.DB, query, section string, limit int) ([]models.TopicBrief, error) {
	if limit <= 0 || limit > 50 {
		limit = 20
	}
	query = strings.TrimSpace(strings.ToLower(query))
	base := db.Model(&models.Topic{}).Where("topics.status = ?", models.TopicStatusActive)
	if query != "" {
		base = base.Where("LOWER(topics.name) LIKE ?", "%"+query+"%")
	}
	var topics []models.Topic
	if err := base.Order("topics.usage_count DESC").Order("topics.name ASC").Limit(limit).Find(&topics).Error; err != nil {
		return nil, err
	}
	// 版块排序先保持确定性；SectionTopicStat 在后续阶段可替换这次轻量统计。
	if section != "" && len(topics) > 1 {
		var rows []struct {
			TopicID uint
			Count   int64
		}
		ids := make([]uint, 0, len(topics))
		for _, topic := range topics {
			ids = append(ids, topic.ID)
		}
		err := db.Table("post_topics AS pt").
			Select("pt.topic_id, COUNT(*) AS count").
			Joins("JOIN posts AS p ON p.id = pt.post_id").
			Where("pt.topic_id IN ? AND p.post_type = ? AND p.status <> ?", ids, section, models.PostStatusDeleted).
			Group("pt.topic_id").Scan(&rows).Error
		if err != nil {
			return nil, err
		}
		counts := make(map[uint]int64, len(rows))
		for _, row := range rows {
			counts[row.TopicID] = row.Count
		}
		for i := 0; i < len(topics); i++ {
			for j := i + 1; j < len(topics); j++ {
				if counts[topics[j].ID] > counts[topics[i].ID] {
					topics[i], topics[j] = topics[j], topics[i]
				}
			}
		}
	}
	result := make([]models.TopicBrief, 0, len(topics))
	for _, topic := range topics {
		result = append(result, models.TopicBrief{ID: topic.ID, Name: topic.Name})
	}
	return result, nil
}
