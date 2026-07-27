package services

import (
	"fmt"
	"regexp"
	"strings"
	"unicode"
	"unicode/utf8"
)

const structuredChunkingVersion = "structured-policy-v1"

var (
	markdownHeadingPattern   = regexp.MustCompile(`^(#{1,6})\s+(.+)$`)
	policySectionPattern     = regexp.MustCompile(`^第([〇零一二两三四五六七八九十百千万0-9]+)(章|节|编|部分)\s*(.*)$`)
	policyArticlePattern     = regexp.MustCompile(`^第([〇零一二两三四五六七八九十百千万0-9]+)条(?:\s|　)*(.*)$`)
	chineseSectionPattern    = regexp.MustCompile(`^([一二两三四五六七八九十百]+)[、.．]\s*(.+)$`)
	arabicItemPattern        = regexp.MustCompile(`^([0-9]+)[、.．]\s*(.+)$`)
	parenthesizedItemPattern = regexp.MustCompile(`^[（(]([〇零一二两三四五六七八九十百千万0-9]+)[）)]\s*(.*)$`)
	faqQuestionPattern       = regexp.MustCompile(`(?i)^(?:Q(?:uestion)?\s*[0-9]*|问(?:题)?\s*[0-9]*)[：:.．\s]`)
	explicitAliasPattern     = regexp.MustCompile(`^(?:[-*+]\s*)?(?:检索别名|别名|同义词|关键词)[：:]\s*(.+)$`)
	markdownNumberPattern    = regexp.MustCompile(`^[0-9]+(?:\.[0-9]+)*[、.．]?\s*`)
	plainPolicyTitlePattern  = regexp.MustCompile(`^关于.{1,30}(?:规定|办法|细则|管理|重修|考试|考核)$`)
)

type knowledgeTextChunk struct {
	Content       string
	SectionTitle  string
	SectionPath   []string
	SourceLocator string
	Aliases       []string
}

type knowledgeParagraph struct {
	text    string
	isTable bool
}

type knowledgeSemanticUnit struct {
	knowledgeTextChunk
	kind string
}

type knowledgeChunkParser struct {
	headingPath    []string
	structuralPath []string
	sectionTitle   string
	locatorBase    string
	pendingHeaders []string
	current        *knowledgeSemanticUnit
	units          []knowledgeSemanticUnit
}

// splitKnowledgeDocument 按政策结构生成证据块；maxRunes 是软目标，完整条款最多可放宽到两倍后再按完整句子拆分。
func splitKnowledgeDocument(content string, maxRunes, overlapRunes int) []knowledgeTextChunk {
	if maxRunes <= 0 {
		maxRunes = 700
	}
	if overlapRunes < 0 {
		overlapRunes = 0
	}
	paragraphs := splitKnowledgeParagraphs(content)
	parser := knowledgeChunkParser{units: make([]knowledgeSemanticUnit, 0, len(paragraphs))}
	for _, paragraph := range paragraphs {
		parser.consume(paragraph)
	}
	parser.flushCurrent()
	parser.flushPendingHeaders()

	chunks := make([]knowledgeTextChunk, 0, len(parser.units))
	for _, unit := range parser.units {
		unit.Aliases = extractKnowledgeAliases(unit.SectionTitle, unit.Content)
		for _, expanded := range splitOversizedKnowledgeUnit(unit, maxRunes, overlapRunes) {
			chunks = append(chunks, expanded.knowledgeTextChunk)
		}
	}
	return chunks
}

func splitKnowledgeParagraphs(content string) []knowledgeParagraph {
	content = strings.ReplaceAll(strings.ReplaceAll(content, "\r\n", "\n"), "\r", "\n")
	lines := strings.Split(content, "\n")
	paragraphs := make([]knowledgeParagraph, 0, len(lines))
	buffer := make([]string, 0, 4)
	bufferIsTable := false
	flush := func() {
		text := strings.TrimSpace(strings.Join(buffer, "\n"))
		if text != "" {
			paragraphs = append(paragraphs, knowledgeParagraph{text: text, isTable: bufferIsTable})
		}
		buffer = buffer[:0]
		bufferIsTable = false
	}
	for _, rawLine := range lines {
		line := strings.TrimSpace(rawLine)
		if line == "" {
			flush()
			continue
		}
		isTable := isMarkdownTableLine(line)
		if len(buffer) > 0 && (isTable != bufferIsTable || (!isTable && isKnowledgeBoundaryLine(line))) {
			flush()
		}
		bufferIsTable = isTable
		buffer = append(buffer, line)
	}
	flush()
	return paragraphs
}

func isKnowledgeBoundaryLine(line string) bool {
	return markdownHeadingPattern.MatchString(line) || policySectionPattern.MatchString(line) ||
		policyArticlePattern.MatchString(line) || chineseSectionPattern.MatchString(line) ||
		arabicItemPattern.MatchString(line) || parenthesizedItemPattern.MatchString(line) ||
		faqQuestionPattern.MatchString(line) || plainPolicyTitlePattern.MatchString(line) ||
		isFAQQuestion(line) || isTableTitle(line)
}

func (p *knowledgeChunkParser) consume(paragraph knowledgeParagraph) {
	text := strings.TrimSpace(paragraph.text)
	if text == "" {
		return
	}
	if match := markdownHeadingPattern.FindStringSubmatch(text); match != nil {
		p.flushCurrent()
		level := len(match[1])
		title := strings.TrimSpace(match[2])
		p.setMarkdownHeading(level, title)
		p.pendingHeaders = append(p.pendingHeaders, text)
		return
	}
	if match := policySectionPattern.FindStringSubmatch(text); match != nil {
		p.flushCurrent()
		label := "第" + match[1] + match[2]
		p.sectionTitle = strings.TrimSpace(label + " " + match[3])
		p.locatorBase = label
		p.structuralPath = append(compactSectionPath(p.headingPath), p.sectionTitle)
		p.pendingHeaders = append(p.pendingHeaders, text)
		return
	}
	if match := chineseSectionPattern.FindStringSubmatch(text); match != nil {
		p.flushCurrent()
		p.sectionTitle = strings.TrimSpace(match[0])
		p.locatorBase = "第" + match[1] + "部分"
		p.structuralPath = append(compactSectionPath(p.headingPath), p.sectionTitle)
		p.pendingHeaders = append(p.pendingHeaders, text)
		return
	}
	if match := policyArticlePattern.FindStringSubmatch(text); match != nil {
		p.flushCurrent()
		label := "第" + match[1] + "条"
		p.startUnit("article", text, label, label)
		return
	}
	if plainPolicyTitlePattern.MatchString(text) {
		p.flushCurrent()
		p.sectionTitle = text
		p.locatorBase = text
		p.structuralPath = append(compactSectionPath(p.headingPath), text)
		p.pendingHeaders = append(p.pendingHeaders, text)
		return
	}
	if match := arabicItemPattern.FindStringSubmatch(text); match != nil {
		p.flushCurrent()
		locator := "第" + match[1] + "项"
		if p.locatorBase != "" {
			locator = p.locatorBase + locator
		}
		p.startUnit("item", text, p.sectionTitle, locator)
		return
	}
	if match := parenthesizedItemPattern.FindStringSubmatch(text); match != nil {
		if p.current != nil && p.current.kind == "article" {
			p.appendCurrent(text)
			return
		}
		p.flushCurrent()
		locator := "第" + match[1] + "项"
		if p.locatorBase != "" {
			locator = p.locatorBase + locator
		}
		p.startUnit("item", text, p.sectionTitle, locator)
		return
	}
	if paragraph.isTable {
		if p.current != nil && p.current.kind == "table" {
			p.appendCurrent(text)
			return
		}
		p.flushCurrent()
		locator := p.locatorBase
		if locator == "" {
			locator = "表格"
		} else {
			locator += "表格"
		}
		p.startUnit("table", text, p.sectionTitle, locator)
		return
	}
	if isTableTitle(text) {
		p.flushCurrent()
		p.startUnit("table", text, p.sectionTitle, readableTableLocator(text, p.locatorBase))
		return
	}
	if faqQuestionPattern.MatchString(text) || isFAQQuestion(text) {
		p.flushCurrent()
		locator := strings.TrimSpace(strings.SplitN(text, "\n", 2)[0])
		if utf8.RuneCountInString(locator) > 80 {
			locator = truncateRunes(locator, 80)
		}
		p.startUnit("faq", text, locator, locator)
		return
	}
	if p.current == nil {
		locator := p.locatorBase
		if locator == "" {
			locator = "正文"
		}
		p.startUnit("plain", text, p.sectionTitle, locator)
		return
	}
	p.appendCurrent(text)
}

func (p *knowledgeChunkParser) setMarkdownHeading(level int, title string) {
	if level < 1 {
		level = 1
	}
	if len(p.headingPath) >= level {
		p.headingPath = p.headingPath[:level-1]
	}
	for len(p.headingPath) < level-1 {
		p.headingPath = append(p.headingPath, "")
	}
	p.headingPath = append(p.headingPath, title)
	p.structuralPath = compactSectionPath(p.headingPath)
	p.sectionTitle = title
	p.locatorBase = cleanHeadingLocator(title)
}

func (p *knowledgeChunkParser) startUnit(kind, text, sectionTitle, locator string) {
	contentParts := append([]string(nil), p.pendingHeaders...)
	contentParts = append(contentParts, strings.TrimSpace(text))
	p.pendingHeaders = p.pendingHeaders[:0]
	sectionPath := compactSectionPath(p.structuralPath)
	if len(sectionPath) == 0 {
		sectionPath = compactSectionPath(p.headingPath)
	}
	if sectionTitle != "" && (len(sectionPath) == 0 || sectionPath[len(sectionPath)-1] != sectionTitle) {
		sectionPath = append(sectionPath, sectionTitle)
	}
	p.current = &knowledgeSemanticUnit{
		knowledgeTextChunk: knowledgeTextChunk{
			Content:       strings.TrimSpace(strings.Join(contentParts, "\n\n")),
			SectionTitle:  truncateRunes(strings.TrimSpace(sectionTitle), 500),
			SectionPath:   sectionPath,
			SourceLocator: truncateRunes(strings.TrimSpace(locator), 500),
		},
		kind: kind,
	}
}

func (p *knowledgeChunkParser) appendCurrent(text string) {
	if p.current == nil || strings.TrimSpace(text) == "" {
		return
	}
	p.current.Content = strings.TrimSpace(p.current.Content + "\n\n" + strings.TrimSpace(text))
}

func (p *knowledgeChunkParser) flushCurrent() {
	if p.current == nil {
		return
	}
	if strings.TrimSpace(p.current.Content) != "" {
		p.units = append(p.units, *p.current)
	}
	p.current = nil
}

func (p *knowledgeChunkParser) flushPendingHeaders() {
	if len(p.pendingHeaders) == 0 {
		return
	}
	locator := p.locatorBase
	if locator == "" {
		locator = "正文"
	}
	p.startUnit("plain", "", p.sectionTitle, locator)
	p.flushCurrent()
}

func splitOversizedKnowledgeUnit(unit knowledgeSemanticUnit, maxRunes, overlapRunes int) []knowledgeSemanticUnit {
	if unit.kind == "table" || utf8.RuneCountInString(unit.Content) <= maxRunes*2 {
		return []knowledgeSemanticUnit{unit}
	}
	segments := splitKnowledgeSentences(unit.Content, maxRunes*2)
	groups := groupKnowledgeSegments(segments, maxRunes, overlapRunes)
	if len(groups) <= 1 {
		return []knowledgeSemanticUnit{unit}
	}
	result := make([]knowledgeSemanticUnit, 0, len(groups))
	for index, group := range groups {
		part := unit
		part.Content = strings.TrimSpace(strings.Join(group, ""))
		part.SourceLocator = fmt.Sprintf("%s（第%d段）", unit.SourceLocator, index+1)
		result = append(result, part)
	}
	return result
}

func splitKnowledgeSentences(text string, hardLimit int) []string {
	if hardLimit <= 0 {
		return []string{text}
	}
	runes := []rune(text)
	segments := make([]string, 0, len(runes)/hardLimit+1)
	start := 0
	for index, current := range runes {
		boundary := current == '。' || current == '！' || current == '？' || current == '；' || current == '\n'
		if boundary {
			appendKnowledgeSegment(&segments, runes[start:index+1], hardLimit)
			start = index + 1
		}
	}
	appendKnowledgeSegment(&segments, runes[start:], hardLimit)
	return segments
}

func appendKnowledgeSegment(segments *[]string, runes []rune, hardLimit int) {
	text := strings.TrimSpace(string(runes))
	if text == "" {
		return
	}
	for utf8.RuneCountInString(text) > hardLimit {
		part, rest := splitAtSemanticPunctuation(text, hardLimit)
		*segments = append(*segments, part)
		text = rest
	}
	if text != "" {
		*segments = append(*segments, text)
	}
}

func splitAtSemanticPunctuation(text string, limit int) (string, string) {
	runes := []rune(text)
	if len(runes) <= limit {
		return text, ""
	}
	cut := limit
	for index := limit - 1; index >= limit/2; index-- {
		if strings.ContainsRune("，,、；;：:", runes[index]) {
			cut = index + 1
			break
		}
	}
	return strings.TrimSpace(string(runes[:cut])), strings.TrimSpace(string(runes[cut:]))
}

func groupKnowledgeSegments(segments []string, maxRunes, overlapRunes int) [][]string {
	groups := make([][]string, 0, len(segments))
	current := make([]string, 0, 4)
	currentRunes := 0
	for _, segment := range segments {
		length := utf8.RuneCountInString(segment)
		if len(current) > 0 && currentRunes+length > maxRunes {
			groups = append(groups, current)
			current = wholeSegmentOverlap(current, overlapRunes)
			currentRunes = runeCountStrings(current)
		}
		current = append(current, segment)
		currentRunes += length
	}
	if len(current) > 0 {
		groups = append(groups, current)
	}
	return groups
}

func wholeSegmentOverlap(segments []string, overlapRunes int) []string {
	if overlapRunes <= 0 || len(segments) == 0 {
		return nil
	}
	start := len(segments)
	total := 0
	for start > 0 {
		length := utf8.RuneCountInString(segments[start-1])
		if total > 0 && total+length > overlapRunes {
			break
		}
		total += length
		start--
		if total >= overlapRunes {
			break
		}
	}
	return append([]string(nil), segments[start:]...)
}

func extractKnowledgeAliases(sectionTitle, content string) []string {
	aliases := make([]string, 0, 8)
	seen := make(map[string]struct{})
	add := func(value string) {
		value = strings.Trim(strings.TrimSpace(value), "`*_\"'“”‘’《》")
		if value == "" || utf8.RuneCountInString(value) > 100 {
			return
		}
		key := strings.ToLower(value)
		if _, exists := seen[key]; exists {
			return
		}
		seen[key] = struct{}{}
		aliases = append(aliases, value)
	}
	for _, line := range strings.Split(content, "\n") {
		line = strings.TrimSpace(line)
		if match := explicitAliasPattern.FindStringSubmatch(line); match != nil {
			for _, alias := range strings.FieldsFunc(match[1], func(value rune) bool {
				return strings.ContainsRune("、,，;/；|", value)
			}) {
				add(alias)
			}
		}
		if strings.Contains(sectionTitle, "术语") && isMarkdownTableLine(line) && !strings.Contains(line, "---") {
			for _, cell := range strings.Split(strings.Trim(line, "|"), "|") {
				cell = strings.TrimSpace(cell)
				if cell != "学生常用说法" && cell != "制度用语" {
					add(cell)
				}
			}
		}
	}
	if len(aliases) > 32 {
		aliases = aliases[:32]
	}
	return aliases
}

func isMarkdownTableLine(line string) bool {
	line = strings.TrimSpace(line)
	return strings.HasPrefix(line, "|") && strings.Count(line, "|") >= 2
}

func isTableTitle(text string) bool {
	firstLine := strings.TrimSpace(strings.SplitN(text, "\n", 2)[0])
	if utf8.RuneCountInString(firstLine) > 100 {
		return false
	}
	if strings.HasPrefix(firstLine, "表") {
		rest := strings.TrimSpace(strings.TrimPrefix(firstLine, "表"))
		return rest != "" && (unicode.IsDigit([]rune(rest)[0]) || strings.ContainsRune("一二三四五六七八九十", []rune(rest)[0]))
	}
	return strings.HasSuffix(firstLine, "对照表") || strings.HasSuffix(firstLine, "一览表") || strings.HasSuffix(firstLine, "规则表")
}

func readableTableLocator(text, fallback string) string {
	firstLine := strings.TrimSpace(strings.SplitN(text, "\n", 2)[0])
	if utf8.RuneCountInString(firstLine) <= 100 {
		return firstLine
	}
	if fallback != "" {
		return fallback + "表格"
	}
	return "表格"
}

func isFAQQuestion(text string) bool {
	firstLine := strings.TrimSpace(strings.SplitN(text, "\n", 2)[0])
	return utf8.RuneCountInString(firstLine) <= 120 && (strings.HasSuffix(firstLine, "？") || strings.HasSuffix(firstLine, "?"))
}

func cleanHeadingLocator(title string) string {
	title = markdownNumberPattern.ReplaceAllString(strings.TrimSpace(title), "")
	if title == "" {
		return "正文"
	}
	return title
}

func compactSectionPath(path []string) []string {
	result := make([]string, 0, len(path))
	for _, item := range path {
		item = strings.TrimSpace(item)
		if item != "" {
			result = append(result, item)
		}
	}
	return result
}

func runeCountStrings(values []string) int {
	total := 0
	for _, value := range values {
		total += utf8.RuneCountInString(value)
	}
	return total
}

func truncateRunes(value string, limit int) string {
	if limit <= 0 {
		return ""
	}
	runes := []rune(value)
	if len(runes) <= limit {
		return value
	}
	return string(runes[:limit])
}
