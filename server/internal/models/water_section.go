package models

import (
	"encoding/json"
	"time"

	"gorm.io/gorm"
)

// WaterSection 校园社区版块（水帖一级容器）
type WaterSection struct {
	ID                  uint      `gorm:"primaryKey" json:"id"`
	Slug                string    `gorm:"size:64;uniqueIndex;not null" json:"slug"`
	Title               string    `gorm:"size:64;not null" json:"title"`
	Subtitle            string    `gorm:"size:200" json:"subtitle"`
	Description         string    `gorm:"size:1000" json:"description"`
	IconKey             string    `gorm:"size:64" json:"icon_key"`
	ColorHex            string    `gorm:"size:20" json:"color_hex"`
	PublishActionText   string    `gorm:"size:40" json:"publish_action_text"`
	EmptyTitle          string    `gorm:"size:100" json:"empty_title"`
	EmptyDescription    string    `gorm:"size:300" json:"empty_description"`
	StarterQuestionsJSON string   `gorm:"type:text" json:"starter_questions_json"`
	NoticeText          string    `gorm:"size:1000" json:"notice_text"`
	SensitiveLevel      string    `gorm:"size:20;default:'normal';index" json:"sensitive_level"`
	DefaultSort         string    `gorm:"size:20;default:'recommend'" json:"default_sort"`
	SortOrder           int       `gorm:"default:0;index" json:"sort_order"`
	Status              string    `gorm:"size:20;default:'active';index" json:"status"`
	CreatedAt           time.Time `json:"created_at"`
	UpdatedAt           time.Time `json:"updated_at"`

	// Tags 版块内标签，Preload 时按业务需要进一步过滤
	Tags []WaterSectionTag `gorm:"foreignKey:SectionID" json:"tags"`
}

func (WaterSection) TableName() string { return "water_sections" }

// WaterSectionTag 版块内标签（二级分类）
type WaterSectionTag struct {
	ID          uint      `gorm:"primaryKey" json:"id"`
	SectionID   uint      `gorm:"not null;index;uniqueIndex:idx_section_tag_slug" json:"section_id"`
	Slug        string    `gorm:"size:64;not null;index;uniqueIndex:idx_section_tag_slug" json:"slug"`
	Name        string    `gorm:"size:40;not null" json:"name"`
	Description string    `gorm:"size:200" json:"description"`
	SortOrder   int       `gorm:"default:0;index" json:"sort_order"`
	IsDefault   bool      `gorm:"default:false" json:"is_default"`
	IsEnabled   bool      `gorm:"default:true;index" json:"is_enabled"`
	CreatedAt   time.Time `json:"created_at"`
	UpdatedAt   time.Time `json:"updated_at"`
}

func (WaterSectionTag) TableName() string { return "water_section_tags" }

// WaterSectionModeratorRole 版块管理角色
const (
	ModeratorRoleOwner     = "owner"
	ModeratorRoleModerator = "moderator"
)

// WaterSectionModeratorStatus
const (
	ModeratorStatusActive  = "active"
	ModeratorStatusRevoked = "revoked"
)

// WaterSectionModerator 版块局部权限（不是 user.role，是用户在某个版块下的管理身份）
type WaterSectionModerator struct {
	ID        uint `gorm:"primaryKey" json:"id"`
	SectionID uint `gorm:"index;not null" json:"section_id"`
	UserID    uint `gorm:"index;not null" json:"user_id"`

	Role string `gorm:"size:32;not null;default:'moderator'" json:"role"`

	CanEditSection bool `gorm:"not null;default:false" json:"can_edit_section"`
	CanManageTags  bool `gorm:"not null;default:false" json:"can_manage_tags"`
	CanPinPost     bool `gorm:"not null;default:false" json:"can_pin_post"`
	CanDeletePost  bool `gorm:"not null;default:false" json:"can_delete_post"`
	CanMuteUser    bool `gorm:"not null;default:false" json:"can_mute_user"`

	Status string `gorm:"size:32;index;not null;default:'active'" json:"status"`

	AssignedBy    uint   `gorm:"index;not null" json:"assigned_by"`
	AssignReason  string `gorm:"size:500" json:"assign_reason"`

	RevokedBy     *uint      `gorm:"index" json:"revoked_by"`
	RevokedAt     *time.Time `json:"revoked_at"`
	RevokeReason  string     `gorm:"size:500" json:"revoke_reason"`

	CreatedAt time.Time `json:"created_at"`
	UpdatedAt time.Time `json:"updated_at"`

	// 关联（可选，按需 Preload）
	Section WaterSection `gorm:"foreignKey:SectionID" json:"section,omitempty"`
	User    User         `gorm:"foreignKey:UserID" json:"user,omitempty"`
}

func (WaterSectionModerator) TableName() string { return "water_section_moderators" }

// waterSectionSeedEntry seed 表条目
type waterSectionSeedEntry struct {
	Slug              string
	Title             string
	Subtitle          string
	Description       string
	IconKey           string
	ColorHex          string
	PublishActionText string
	EmptyTitle        string
	EmptyDescription  string
	StarterQuestions  []string
	NoticeText        string
	SensitiveLevel    string
	DefaultSort       string
	SortOrder         int
	Tags              []waterSectionTagSeed
}

type waterSectionTagSeed struct {
	Slug        string
	Name        string
	Description string
	SortOrder   int
	IsDefault   bool
}

func defaultWaterSections() []waterSectionSeedEntry {
	return []waterSectionSeedEntry{
		{
			Slug: "freshman_help", Title: "新生求助",
			Subtitle: "新生群、宿舍、入学流程、校园问题",
			Description: "面向新生的入学指引、报到流程、宿舍选择、校园卡办理等问答。",
			IconKey: "school", ColorHex: "#4A90E2", PublishActionText: "提一个问题",
			EmptyTitle: "还没有「新生求助」相关帖子",
			EmptyDescription: "可以提问宿舍、报到流程、军训、校园卡、新生群等问题。",
			StarterQuestions: []string{"宿舍怎么选？", "报到流程是什么？", "军训要准备什么？", "校园卡怎么办理？", "新生群在哪？"},
			SensitiveLevel: "normal", DefaultSort: "recommend", SortOrder: 10,
			Tags: []waterSectionTagSeed{
				{Slug: "dormitory", Name: "宿舍", SortOrder: 10},
				{Slug: "admission", Name: "入学", SortOrder: 20},
				{Slug: "military_training", Name: "军训", SortOrder: 30},
				{Slug: "campus_card", Name: "校园卡", SortOrder: 40},
				{Slug: "freshman_group", Name: "新生群", SortOrder: 50},
			},
		},
		{
			Slug: "course_study", Title: "课程学习",
			Subtitle: "课程、考试、选课、老师、学习资料",
			Description: "课程评价、选课建议、考试复习、老师风格、学习资料共享等。",
			IconKey: "menu_book", ColorHex: "#2DBE72", PublishActionText: "提一个问题",
			EmptyTitle: "还没有「课程学习」相关帖子",
			EmptyDescription: "可以分享选课、考试、老师评价或学习资料线索。",
			StarterQuestions: []string{"这门课难不难？", "老师给分怎么样？", "考试怎么复习？", "选课有什么建议？", "学习资料去哪找？"},
			SensitiveLevel: "normal", DefaultSort: "recommend", SortOrder: 20,
			Tags: []waterSectionTagSeed{
				{Slug: "course_select", Name: "选课", SortOrder: 10},
				{Slug: "exam", Name: "考试", SortOrder: 20},
				{Slug: "teacher", Name: "老师", SortOrder: 30},
				{Slug: "materials", Name: "学习资料", SortOrder: 40},
				{Slug: "gpa", Name: "绩点", SortOrder: 50},
			},
		},
		{
			Slug: "competition", Title: "比赛竞赛",
			Subtitle: "竞赛通知、经验、组队、备赛",
			Description: "竞赛通知、组队、经验分享、备赛攻略、学校认定。",
			IconKey: "emoji_events", ColorHex: "#F5A623", PublishActionText: "发布帖子",
			EmptyTitle: "还没有「比赛竞赛」相关帖子",
			EmptyDescription: "可以发布竞赛通知、组队、经验、避坑等帖子。",
			StarterQuestions: []string{"有哪些重要竞赛通知？", "怎么组队？", "备赛经验有什么？", "学校认定范围？", "怎么避坑？"},
			SensitiveLevel: "normal", DefaultSort: "recommend", SortOrder: 30,
			Tags: []waterSectionTagSeed{
				{Slug: "notice", Name: "通知", SortOrder: 10},
				{Slug: "team", Name: "组队", SortOrder: 20},
				{Slug: "experience", Name: "经验", SortOrder: 30},
				{Slug: "algorithm", Name: "算法", SortOrder: 40},
				{Slug: "modeling", Name: "数模", SortOrder: 50},
			},
		},
		{
			Slug: "campus_life", Title: "校园生活",
			Subtitle: "日常、宿舍、食堂、校园见闻",
			Description: "校园日常、宿舍食堂、校园卡、随手拍、校园见闻。",
			IconKey: "local_florist", ColorHex: "#7ED321", PublishActionText: "发布帖子",
			EmptyTitle: "还没有「校园生活」相关帖子",
			EmptyDescription: "可以分享食堂、宿舍、校园卡、随手拍、校园见闻。",
			StarterQuestions: []string{"食堂哪家强？", "宿舍怎么样？", "校园卡丢了怎么办？", "校园里有什么好去处？", "随手拍分享什么？"},
			SensitiveLevel: "normal", DefaultSort: "recommend", SortOrder: 40,
			Tags: []waterSectionTagSeed{
				{Slug: "canteen", Name: "食堂", SortOrder: 10},
				{Slug: "dormitory", Name: "宿舍", SortOrder: 20},
				{Slug: "daily", Name: "日常", SortOrder: 30},
				{Slug: "campus_card", Name: "校园卡", SortOrder: 40},
				{Slug: "snapshot", Name: "随手拍", SortOrder: 50},
			},
		},
		{
			Slug: "complaint", Title: "吐槽树洞",
			Subtitle: "吐槽、情绪、烦恼、匿名倾诉",
			Description: "理性吐槽、情绪倾诉、烦恼分享。注意保护隐私、避免挂人。",
			IconKey: "mood", ColorHex: "#9B51E0", PublishActionText: "发帖倾诉",
			EmptyTitle: "还没有「吐槽树洞」相关帖子",
			EmptyDescription: "可以理性倾诉情绪、吐槽烦恼、求助压力。",
			StarterQuestions: []string{"最近有什么烦心事？", "学习压力大吗？", "人际关系怎么处理？", "情绪怎么排解？", "想吐槽什么？"},
			NoticeText:     "请理性表达，避免公开他人隐私、联系方式、学号、手机号或未经证实的指控。",
			SensitiveLevel: "caution", DefaultSort: "recommend", SortOrder: 50,
			Tags: []waterSectionTagSeed{
				{Slug: "emotion", Name: "情绪", SortOrder: 10},
				{Slug: "complain", Name: "吐槽", SortOrder: 20},
				{Slug: "relationship", Name: "人际", SortOrder: 30},
				{Slug: "study_pressure", Name: "学业压力", SortOrder: 40},
				{Slug: "life_pressure", Name: "生活压力", SortOrder: 50},
			},
		},
		{
			Slug: "experience", Title: "经验分享",
			Subtitle: "攻略、总结、避坑、学习经验",
			Description: "学习攻略、流程总结、实习经验、考证经验、长期有效的分享。",
			IconKey: "lightbulb", ColorHex: "#F2994A", PublishActionText: "分享经验",
			EmptyTitle: "还没有「经验分享」相关帖子",
			EmptyDescription: "可以分享攻略、总结、实习、考证、学习经验。",
			StarterQuestions: []string{"有什么好用的攻略？", "实习怎么准备？", "考证流程是什么？", "怎么避坑？", "学习经验分享？"},
			SensitiveLevel: "normal", DefaultSort: "recommend", SortOrder: 60,
			Tags: []waterSectionTagSeed{
				{Slug: "guide", Name: "攻略", SortOrder: 10},
				{Slug: "summary", Name: "总结", SortOrder: 20},
				{Slug: "internship", Name: "实习", SortOrder: 30},
				{Slug: "exam_pass", Name: "考证", SortOrder: 40},
				{Slug: "study", Name: "学习", SortOrder: 50},
			},
		},
		{
			Slug: "campus_news", Title: "避雷专区",
			Subtitle: "校园避坑、风险提醒、真实经历",
			Description: "消费避坑、校园风险、流程坑点、真实反馈。请客观描述事实。",
			IconKey: "warning", ColorHex: "#EB5757", PublishActionText: "发布提醒",
			EmptyTitle: "还没有「避雷专区」相关帖子",
			EmptyDescription: "可以发布消费避坑、校园风险、流程坑点、真实反馈。",
			StarterQuestions: []string{"遇到过什么消费陷阱？", "校园里有什么风险？", "流程上有坑吗？", "真实经历分享？", "二手交易注意什么？"},
			NoticeText:     "请客观描述事实，避免挂人、泄露隐私、传播未经证实的信息。",
			SensitiveLevel: "strict", DefaultSort: "recommend", SortOrder: 70,
			Tags: []waterSectionTagSeed{
				{Slug: "risk", Name: "风险提醒", SortOrder: 10},
				{Slug: "secondhand", Name: "二手避坑", SortOrder: 20},
				{Slug: "merchant", Name: "商家", SortOrder: 30},
				{Slug: "dormitory", Name: "宿舍", SortOrder: 40},
				{Slug: "other", Name: "其他", SortOrder: 50},
			},
		},
	}
}

// EnsureWaterSections 启动时确保默认版块与标签存在；不覆盖管理员修改过的字段。
func EnsureWaterSections(db *gorm.DB) error {
	for _, entry := range defaultWaterSections() {
		var section WaterSection
		err := db.Where("slug = ?", entry.Slug).First(&section).Error
		if err == gorm.ErrRecordNotFound {
			questionsJSON, marshalErr := json.Marshal(entry.StarterQuestions)
			if marshalErr != nil {
				return marshalErr
			}
			section = WaterSection{
				Slug:                 entry.Slug,
				Title:                entry.Title,
				Subtitle:             entry.Subtitle,
				Description:          entry.Description,
				IconKey:              entry.IconKey,
				ColorHex:             entry.ColorHex,
				PublishActionText:    entry.PublishActionText,
				EmptyTitle:           entry.EmptyTitle,
				EmptyDescription:     entry.EmptyDescription,
				StarterQuestionsJSON: string(questionsJSON),
				NoticeText:           entry.NoticeText,
				SensitiveLevel:       entry.SensitiveLevel,
				DefaultSort:          entry.DefaultSort,
				SortOrder:            entry.SortOrder,
				Status:               "active",
			}
			if err := db.Create(&section).Error; err != nil {
				return err
			}
		} else if err != nil {
			return err
		}
		// 已存在则不覆盖任何字段

		// tags
		for _, tagSeed := range entry.Tags {
			var tag WaterSectionTag
			tagErr := db.Where("section_id = ? AND slug = ?", section.ID, tagSeed.Slug).First(&tag).Error
			if tagErr == gorm.ErrRecordNotFound {
				tag = WaterSectionTag{
					SectionID:   section.ID,
					Slug:        tagSeed.Slug,
					Name:        tagSeed.Name,
					Description: tagSeed.Description,
					SortOrder:   tagSeed.SortOrder,
					IsDefault:   tagSeed.IsDefault,
					IsEnabled:   true,
				}
				if err := db.Create(&tag).Error; err != nil {
					return err
				}
			} else if tagErr != nil {
				return tagErr
			}
			// 已存在则不覆盖
		}
	}
	return nil
}