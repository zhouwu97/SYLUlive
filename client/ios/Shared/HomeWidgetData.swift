import Foundation

enum HomeWidgetSharedStore {
    static let appGroup = "group.com.sylu.sylulive"

    static func open() -> UserDefaults? {
        #if os(iOS)
        guard FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroup
        ) != nil else { return nil }
        #endif
        return UserDefaults(suiteName: appGroup)
    }

    static func write(_ arguments: [String: Any], to defaults: UserDefaults) {
        let stringKeys = [
            "course_data": "widget_course_data",
            "exam_data": "widget_exam_data",
            "app_palette": "widget_app_palette_v1",
            "course_theme": "widget_course_theme",
            "exam_theme": "widget_exam_theme",
            "course_title": "widget_course_title",
            "exam_title": "widget_exam_title",
        ]
        for (argument, key) in stringKeys {
            if let value = arguments[argument] as? String {
                defaults.set(value, forKey: key)
            } else if arguments[argument] is NSNull {
                // Flutter 清理课程或退出账号时发送 null，必须同步撤回扩展中的旧数据。
                defaults.removeObject(forKey: key)
            }
        }
        for kind in ["course", "exam"] {
            if let value = arguments["\(kind)_frosted_glass"] as? Bool {
                defaults.set(value, forKey: "widget_\(kind)_frosted_glass")
            }
        }
        defaults.set(Date().timeIntervalSince1970, forKey: "widget_updated_at")
    }
}

struct CourseEntry {
    let date: Date
    let title: String
    let dateInfo: String
    let courses: [CourseItem]
    let emptyMessage: String

    var isEmpty: Bool { courses.isEmpty }
}

struct CourseItem: Identifiable {
    let id = UUID()
    let name: String
    let time: String
    let location: String
    let color: String
}

enum HomeWidgetCourseData {
    static func timelineDates(now: Date, calendar: Calendar = .current) -> [Date] {
        // 预先交付跨日内容，避免午夜刷新被系统延后时继续显示前一天的空课表。
        [now] + (1...7).compactMap {
            calendar.date(byAdding: .day, value: $0, to: calendar.startOfDay(for: now))
        }
    }

    static func read(defaults: UserDefaults?, now: Date = Date(),
                     calendar: Calendar = .current) -> CourseEntry {
        let title = defaults?.string(forKey: "widget_course_title") ?? "沈理院课表"
        guard let defaults else {
            return CourseEntry(date: now, title: title, dateInfo: "共享存储不可用",
                courses: [], emptyMessage: "请检查主 App 与小组件的 App Group 签名")
        }
        guard let raw = defaults.string(forKey: "widget_course_data") else {
            return CourseEntry(date: now, title: title, dateInfo: "尚未同步",
                courses: [], emptyMessage: "请打开 App 同步课表")
        }
        guard let bytes = raw.data(using: .utf8),
              let payload = (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any] else {
            return CourseEntry(date: now, title: title, dateInfo: "课表读取失败",
                courses: [], emptyMessage: "请打开 App 重新同步课表")
        }
        var civilCalendar = Calendar(identifier: .gregorian)
        civilCalendar.timeZone = calendar.timeZone
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = civilCalendar
        formatter.timeZone = civilCalendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        let version = (payload["schema_version"] as? Int) ?? 1
        let effectiveTitle = defaults.string(forKey: "widget_course_title")
            ?? payload["title"] as? String ?? title
        let rawCourses = payload["courses"] as? [[String: Any]] ?? []
        if version == 1 {
            let dateKey = payload["date_key"] as? String ?? ""
            if !dateKey.isEmpty && dateKey != formatter.string(from: now) {
                return CourseEntry(date: now, title: effectiveTitle, dateInfo: "暂无今日数据",
                    courses: [], emptyMessage: "请打开 App 同步今日课表")
            }
            let courses = rawCourses.compactMap { item -> CourseItem? in
                guard let name = item["name"] as? String,
                      let time = item["time"] as? String else { return nil }
                return CourseItem(name: name, time: time,
                    location: item["location"] as? String ?? "",
                    color: item["color"] as? String ?? "#6366F1")
            }
            return CourseEntry(date: now, title: effectiveTitle,
                dateInfo: payload["date"] as? String ?? "", courses: courses,
                emptyMessage: "今天没有课啦")
        }
        guard version == 2 else {
            return CourseEntry(date: now, title: effectiveTitle, dateInfo: "课表格式需更新",
                courses: [], emptyMessage: "请更新 App 后重新同步课表")
        }
        let weekday = (civilCalendar.component(.weekday, from: now) + 5) % 7 + 1
        var academicWeek: Int?
        if let start = payload["semester_start"] as? String,
           let startDate = formatter.date(from: start) {
            let days = civilCalendar.dateComponents([.day],
                from: civilCalendar.startOfDay(for: startDate),
                to: civilCalendar.startOfDay(for: now)).day!
            if days < 0 {
                return CourseEntry(date: now, title: effectiveTitle, dateInfo: "尚未开学",
                    courses: [], emptyMessage: "本学期尚未开始")
            }
            academicWeek = days / 7 + 1
        }
        let weekdays = ["一", "二", "三", "四", "五", "六", "日"]
        let weekText = academicWeek.map { "第\($0)周 " } ?? ""
        let dateInfo = "\(civilCalendar.component(.month, from: now)).\(civilCalendar.component(.day, from: now)) \(weekText)周\(weekdays[weekday - 1])"
        let starts = ["08:00", "08:55", "10:00", "10:55", "13:00", "13:55", "14:50", "15:45", "16:40", "17:35", "19:30", "20:25"]
        let ends = ["08:45", "09:40", "10:45", "11:40", "13:45", "14:40", "15:35", "16:30", "17:25", "18:20", "20:15", "21:10"]
        var candidates: [(Int, CourseItem)] = []
        for item in rawCourses {
            guard let name = item["name"] as? String,
                  item["weekday"] as? Int == weekday else { continue }
            if let week = academicWeek, let weeks = item["weeks"] as? [Int],
               !weeks.isEmpty && !weeks.contains(week) { continue }
            let start = max(1, min(12, item["start_section"] as? Int ?? 1))
            let end = max(start, min(12, item["end_section"] as? Int ?? start))
            candidates.append((start, CourseItem(name: name,
                time: "\(starts[start - 1])-\(ends[end - 1])",
                location: item["location"] as? String ?? "",
                color: item["color"] as? String ?? "#6366F1")))
        }
        candidates.sort { $0.0 < $1.0 }
        return CourseEntry(date: now, title: effectiveTitle, dateInfo: dateInfo,
            courses: candidates.map { $0.1 }, emptyMessage: "今天没有课啦")
    }
}
