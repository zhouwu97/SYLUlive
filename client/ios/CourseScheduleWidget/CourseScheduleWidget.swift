import Foundation
import WidgetKit
import SwiftUI

// ── 主题调色板（契约 3.1：支持跟随 App 主题与系统明暗，回退至既有常量） ──

struct WidgetPalette {
    let background: Color
    let primaryText: Color
    let secondaryText: Color
    let mutedText: Color
    let accent: Color
    let divider: Color

    static func defaultCourse() -> WidgetPalette {
        WidgetPalette(
            background: Color.white,
            primaryText: Color(hex: "1A1A2E"),
            secondaryText: Color(hex: "6366F1"),
            mutedText: Color(hex: "9CA3AF"),
            accent: Color(hex: "6366F1"),
            divider: Color(hex: "E5E7EB")
        )
    }

    static func defaultExam() -> WidgetPalette {
        WidgetPalette(
            background: Color.white,
            primaryText: Color(hex: "1A1A2E"),
            secondaryText: Color(hex: "EC4899"),
            mutedText: Color(hex: "9CA3AF"),
            accent: Color(hex: "EC4899"),
            divider: Color(hex: "FBCFE8")
        )
    }

    static func resolve(
        themeKey: String,
        glassKey: String,
        colorScheme: ColorScheme,
        fallback: WidgetPalette
    ) -> WidgetPalette {
        let defaults = UserDefaults(suiteName: "group.com.sylu.sylulive")
        let theme = defaults?.string(forKey: themeKey) ?? "system"
        guard theme == "appTheme",
              let raw = defaults?.string(forKey: "widget_app_palette_v1"),
              let data = raw.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return fallback
        }
        let variantName = colorScheme == .dark ? "dark" : "light"
        guard let variant = json[variantName] as? [String: Any],
              let bgHex = variant["background"] as? String,
              let primaryHex = variant["primaryText"] as? String,
              let secondaryHex = variant["secondaryText"] as? String,
              let mutedHex = variant["mutedText"] as? String,
              let accentHex = variant["accent"] as? String,
              let dividerHex = variant["divider"] as? String else {
            return fallback
        }
        let frosted = defaults?.bool(forKey: glassKey) ?? false
        let baseBg = Color(hex: bgHex, overrideOpacity: frosted ? 0.82 : 1.0)
        return WidgetPalette(
            background: baseBg,
            primaryText: Color(hex: primaryHex),
            secondaryText: Color(hex: secondaryHex),
            mutedText: Color(hex: mutedHex),
            accent: Color(hex: accentHex),
            divider: Color(hex: dividerHex)
        )
    }
}

private struct ScheduleWidgetBackground: ViewModifier {
    let palette: WidgetPalette

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 17.0, *) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .containerBackground(for: .widget) {
                    palette.background
                }
        } else {
            content
                .padding(12)
                .background(palette.background)
                .cornerRadius(16)
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(palette.divider, lineWidth: 0.5))
        }
    }
}

// ── 数据模型 ──
// 与 Flutter 端 HomeWidgetService 的 key 保持一致

struct CourseEntry: TimelineEntry {
    let date: Date
    let title: String
    let dateInfo: String
    let isEmpty: Bool
    let courses: [CourseItem]
}

struct CourseItem: Identifiable {
    let id = UUID()
    let name: String
    let time: String
    let location: String
    let color: String
}

// ── Provider ──
// 从 UserDefaults (App Group) 读取 Flutter 写入的数据

struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> CourseEntry {
        CourseEntry(
            date: Date(),
            title: "沈理院课表",
            dateInfo: "5.19 第12周 周二",
            isEmpty: false,
            courses: [
                CourseItem(name: "高等数学", time: "08:00-09:40", location: "综合楼A201", color: "#448AFF"),
                CourseItem(name: "大学物理", time: "10:00-11:40", location: "综合楼B103", color: "#00C853"),
            ]
        )
    }

    func getSnapshot(in context: Context, completion: @escaping (CourseEntry) -> Void) {
        completion(placeholder(in: context))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<CourseEntry>) -> Void) {
        let entry = readEntry()
        let timeline = Timeline(entries: [entry], policy: .after(nextMidnight()))
        completion(timeline)
    }

    private func nextMidnight() -> Date {
        let calendar = Calendar.current
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: Date()))
        return tomorrow ?? Date().addingTimeInterval(24 * 60 * 60)
    }

    private func readEntry() -> CourseEntry {
        let defaults = UserDefaults(suiteName: "group.com.sylu.sylulive")
        let raw = defaults?.string(forKey: "widget_course_data")
        var title = "沈理院课表"
        var dateInfo = ""
        var courses: [CourseItem] = []

        if let raw,
           let data = raw.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data),
           let payload = object as? [String: Any] {
            let version = (payload["schema_version"] as? Int) ?? 1
            title = payload["title"] as? String ?? title

            if version == 2 {
                let now = Date()
                let calendar = Calendar.current
                let weekday = calendar.component(.weekday, from: now)
                let mappedWeekday = weekday == 1 ? 7 : weekday - 1

                var academicWeek: Int? = nil
                if let startStr = payload["semester_start"] as? String, !startStr.isEmpty {
                    let formatter = DateFormatter()
                    formatter.locale = Locale(identifier: "en_US_POSIX")
                    formatter.dateFormat = "yyyy-MM-dd"
                    if let startDate = formatter.date(from: startStr) {
                        let startOfDay = calendar.startOfDay(for: now)
                        let startOfSemester = calendar.startOfDay(for: startDate)
                        let diffDays = calendar.dateComponents([.day], from: startOfSemester, to: startOfDay).day ?? 0
                        if diffDays >= 0 {
                            academicWeek = (diffDays / 7) + 1
                        }
                    }
                }

                let month = calendar.component(.month, from: now)
                let day = calendar.component(.day, from: now)
                let weekdaySymbols = ["", "一", "二", "三", "四", "五", "六", "日"]
                let weekName = (mappedWeekday >= 1 && mappedWeekday <= 7) ? weekdaySymbols[mappedWeekday] : ""
                let weekText = academicWeek != nil ? "第\(academicWeek!)周 " : ""
                dateInfo = "\(month).\(day) \(weekText)周\(weekName)"

                let starts = ["08:00", "08:55", "10:00", "10:55", "13:00", "13:55", "14:50", "15:45", "16:40", "17:35", "19:30", "20:25"]
                let ends = ["08:45", "09:40", "10:45", "11:40", "13:45", "14:40", "15:35", "16:30", "17:25", "18:20", "20:15", "21:10"]

                let rawCourses = payload["courses"] as? [[String: Any]] ?? []
                var candidateCourses: [(startSection: Int, item: CourseItem)] = []

                for item in rawCourses {
                    guard let name = item["name"] as? String,
                          let itemWeekday = item["weekday"] as? Int,
                          itemWeekday == mappedWeekday else { continue }

                    if let academicWeek = academicWeek,
                       let weeks = item["weeks"] as? [Int],
                       !weeks.isEmpty,
                       !weeks.contains(academicWeek) {
                        continue
                    }

                    let startSection = max(1, min(12, item["start_section"] as? Int ?? 1))
                    let endSection = max(startSection, min(12, item["end_section"] as? Int ?? startSection))
                    let time = "\(starts[startSection - 1])-\(ends[endSection - 1])"
                    candidateCourses.append((
                        startSection: startSection,
                        item: CourseItem(
                            name: name,
                            time: time,
                            location: item["location"] as? String ?? "",
                            color: item["color"] as? String ?? "6366F1"
                        )
                    ))
                }

                candidateCourses.sort { $0.startSection < $1.startSection }
                courses = candidateCourses.map { $0.item }
            } else if version == 1 {
                dateInfo = payload["date"] as? String ?? ""
                if let dateKey = payload["date_key"] as? String,
                   !dateKey.isEmpty,
                   dateKey != currentDateKey() {
                    return CourseEntry(
                        date: Date(),
                        title: title,
                        dateInfo: "暂无今日数据",
                        isEmpty: true,
                        courses: []
                    )
                }
                let rawCourses = payload["courses"] as? [[String: Any]] ?? []
                courses = rawCourses.compactMap { item in
                    guard let name = item["name"] as? String,
                          let time = item["time"] as? String else { return nil }
                    return CourseItem(
                        name: name,
                        time: time,
                        location: item["location"] as? String ?? "",
                        color: item["color"] as? String ?? "6366F1"
                    )
                }
            }
        }

        return CourseEntry(
            date: Date(),
            title: title,
            dateInfo: dateInfo,
            isEmpty: courses.isEmpty,
            courses: courses
        )
    }

    private func currentDateKey() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar.current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }
}

// ── 主视图 ──

struct CourseScheduleWidgetEntryView: View {
    var entry: Provider.Entry

    @Environment(\.widgetFamily) var family
    @Environment(\.colorScheme) var colorScheme

    var body: some View {
        let palette = WidgetPalette.resolve(
            themeKey: "widget_course_theme",
            glassKey: "widget_course_frosted_glass",
            colorScheme: colorScheme,
            fallback: .defaultCourse()
        )
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(entry.title)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(palette.primaryText)
                Spacer()
                Text(entry.dateInfo)
                    .font(.system(size: 11))
                    .foregroundColor(palette.secondaryText)
            }

            Divider()
                .background(palette.divider)

            if entry.isEmpty {
                VStack(spacing: 4) {
                    Spacer()
                    Text("( 〃'▽'〃 )")
                        .font(.system(size: 16))
                        .foregroundColor(palette.mutedText)
                    Text("今天没有课啦")
                        .font(.system(size: 13))
                        .foregroundColor(palette.mutedText)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(entry.courses.prefix(family == .systemSmall ? 2 : 5)) { course in
                        HStack(spacing: 8) {
                            Rectangle()
                                .fill(Color(hex: course.color))
                                .frame(width: 3)
                                .cornerRadius(1.5)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(course.name)
                                    .font(.system(size: 13, weight: .bold))
                                    .foregroundColor(palette.primaryText)
                                    .lineLimit(1)
                                Text(course.time)
                                    .font(.system(size: 11))
                                    .foregroundColor(palette.secondaryText)
                            }
                            Spacer()
                            Text(course.location)
                                .font(.system(size: 11))
                                .foregroundColor(palette.mutedText)
                                .lineLimit(1)
                        }
                    }
                }
            }
        }
        .modifier(ScheduleWidgetBackground(palette: palette))
        .widgetURL(URL(string: "sylulive://schedule"))
    }
}

// ── 考试 Widget ──

struct ExamEntry: TimelineEntry {
    let date: Date
    let exams: [ExamItem]
}

struct ExamItem: Identifiable {
    let id = UUID()
    let name: String
    let date: String
    let time: String
    let location: String
    let countdown: String
}

struct ExamProvider: TimelineProvider {
    func placeholder(in context: Context) -> ExamEntry {
        ExamEntry(date: Date(), exams: [
            ExamItem(name: "高等数学", date: "2026-06-20", time: "08:00-10:00", location: "综合楼A201", countdown: "3天后")
        ])
    }

    func getSnapshot(in context: Context, completion: @escaping (ExamEntry) -> Void) {
        completion(placeholder(in: context))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<ExamEntry>) -> Void) {
        completion(Timeline(entries: [readEntry()], policy: .after(nextMidnight())))
    }

    private func nextMidnight() -> Date {
        let calendar = Calendar.current
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: Date()))
        return tomorrow ?? Date().addingTimeInterval(24 * 60 * 60)
    }

    private func readEntry() -> ExamEntry {
        let defaults = UserDefaults(suiteName: "group.com.sylu.sylulive")
        guard let raw = defaults?.string(forKey: "widget_exam_data"),
              let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let payload = object as? [String: Any],
              let version = (payload["schema_version"] as? Int),
              version >= 1 && version <= 2 else {
            return ExamEntry(date: Date(), exams: [])
        }
        let rawExams = payload["exams"] as? [[String: Any]] ?? []
        let exams = rawExams.compactMap { item -> ExamItem? in
            guard let name = item["name"] as? String else { return nil }
            return ExamItem(
                name: name,
                date: item["date"] as? String ?? "",
                time: item["time"] as? String ?? "",
                location: item["location"] as? String ?? "",
                countdown: item["countdown"] as? String ?? ""
            )
        }
        return ExamEntry(date: Date(), exams: exams)
    }
}

struct ExamScheduleWidgetEntryView: View {
    var entry: ExamProvider.Entry

    @Environment(\.colorScheme) var colorScheme

    var body: some View {
        let palette = WidgetPalette.resolve(
            themeKey: "widget_exam_theme",
            glassKey: "widget_exam_frosted_glass",
            colorScheme: colorScheme,
            fallback: .defaultExam()
        )
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("考试安排")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(palette.primaryText)
                Spacer()
                Text("沈理院")
                    .font(.system(size: 11))
                    .foregroundColor(palette.accent)
            }
            Divider()
                .background(palette.divider)
            if entry.exams.isEmpty {
                Spacer()
                Text("近期没有考试")
                    .font(.system(size: 13))
                    .foregroundColor(palette.mutedText)
                    .frame(maxWidth: .infinity)
                Spacer()
            } else {
                ForEach(entry.exams.prefix(3)) { exam in
                    HStack(spacing: 8) {
                        Rectangle()
                            .fill(palette.accent)
                            .frame(width: 3)
                            .cornerRadius(1.5)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(exam.name)
                                .font(.system(size: 13, weight: .bold))
                                .foregroundColor(palette.primaryText)
                                .lineLimit(1)
                            Text([exam.date, exam.time].filter { !$0.isEmpty }.joined(separator: " "))
                                .font(.system(size: 11))
                                .foregroundColor(palette.secondaryText)
                        }
                        Spacer()
                        Text(exam.countdown)
                            .font(.system(size: 11))
                            .foregroundColor(palette.mutedText)
                    }
                }
            }
        }
        .modifier(ScheduleWidgetBackground(palette: palette))
        .widgetURL(URL(string: "sylulive://exam"))
    }
}

struct ExamScheduleWidget: Widget {
    let kind: String = "ExamScheduleWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: ExamProvider()) { entry in
            ExamScheduleWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("沈理考试")
        .description("显示近期考试安排")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

// ── Widget 入口 ──

struct CourseScheduleWidget: Widget {
    let kind: String = "CourseScheduleWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: Provider()) { entry in
            CourseScheduleWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("沈理课表")
        .description("显示当天课程安排")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

@main
struct SYLUliveWidgetBundle: WidgetBundle {
    var body: some Widget {
        CourseScheduleWidget()
        ExamScheduleWidget()
    }
}

// ── 辅助：十六进制颜色 ──

extension Color {
    init(hex: String, overrideOpacity: Double? = nil) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 6:
            (a, r, g, b) = (255, (int >> 16) & 0xFF, (int >> 8) & 0xFF, int & 0xFF)
        case 8:
            (a, r, g, b) = ((int >> 24) & 0xFF, (int >> 16) & 0xFF, (int >> 8) & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (255, 0, 0, 0)
        }
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: overrideOpacity ?? (Double(a) / 255)
        )
    }
}
