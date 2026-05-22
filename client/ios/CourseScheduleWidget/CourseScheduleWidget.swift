import WidgetKit
import SwiftUI

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
                CourseItem(name: "高等数学", time: "08:00-09:40", location: "综合楼A201"),
                CourseItem(name: "大学物理", time: "10:00-11:40", location: "综合楼B103"),
            ]
        )
    }

    func getSnapshot(in context: Context, completion: @escaping (CourseEntry) -> Void) {
        completion(placeholder(in: context))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<CourseEntry>) -> Void) {
        let entry = readEntry()
        // 不设置自动刷新策略（由 Flutter 端主动推送更新）
        let timeline = Timeline(entries: [entry], policy: .never)
        completion(timeline)
    }

    private func readEntry() -> CourseEntry {
        let defaults = UserDefaults(suiteName: "group.com.example.shenliyuan")
        let title = defaults?.string(forKey: "widget_title") ?? "沈理院课表"
        let dateInfo = defaults?.string(forKey: "widget_date") ?? ""
        let content = defaults?.string(forKey: "widget_content") ?? ""
        let isEmpty = defaults?.bool(forKey: "widget_empty") ?? true

        var courses: [CourseItem] = []
        if !isEmpty && !content.isEmpty {
            let lines = content.components(separatedBy: "\n")
            for line in lines {
                let parts = line.components(separatedBy: "|")
                if parts.count >= 2 {
                    courses.append(CourseItem(
                        name: parts[0],
                        time: parts[1],
                        location: parts.count > 2 ? parts[2] : ""
                    ))
                }
            }
        }

        return CourseEntry(
            date: Date(),
            title: title,
            dateInfo: dateInfo,
            isEmpty: isEmpty,
            courses: courses
        )
    }
}

// ── 主视图 ──

struct CourseScheduleWidgetEntryView: View {
    var entry: Provider.Entry

    @Environment(\.widgetFamily) var family

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // 标题栏
            HStack {
                Text(entry.title)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(Color(hex: "1A1A2E"))
                Spacer()
                Text(entry.dateInfo)
                    .font(.system(size: 11))
                    .foregroundColor(Color(hex: "6366F1"))
            }

            Divider()

            // 内容区
            if entry.isEmpty {
                VStack(spacing: 4) {
                    Spacer()
                    Text("( 〃'▽'〃 )")
                        .font(.system(size: 16))
                        .foregroundColor(Color(hex: "9CA3AF"))
                    Text("今天没有课啦")
                        .font(.system(size: 13))
                        .foregroundColor(Color(hex: "9CA3AF"))
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(entry.courses.prefix(family == .systemSmall ? 2 : 5)) { course in
                        HStack(spacing: 8) {
                            Rectangle()
                                .fill(Color(hex: "6366F1"))
                                .frame(width: 3)
                                .cornerRadius(1.5)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(course.name)
                                    .font(.system(size: 13, weight: .bold))
                                    .foregroundColor(Color(hex: "1A1A2E"))
                                    .lineLimit(1)
                                Text(course.time)
                                    .font(.system(size: 11))
                                    .foregroundColor(Color(hex: "6366F1"))
                            }
                            Spacer()
                            Text(course.location)
                                .font(.system(size: 11))
                                .foregroundColor(Color(hex: "9CA3AF"))
                                .lineLimit(1)
                        }
                    }
                }
            }
        }
        .padding(12)
        .background(Color.white)
        .cornerRadius(16)
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color(hex: "E5E7EB"), lineWidth: 0.5)
        )
        .widgetURL(URL(string: "timetable://home"))
    }
}

// ── Widget 入口 ──

@main
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

// ── 辅助：十六进制颜色 ──

extension Color {
    init(hex: String) {
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
            opacity: Double(a) / 255
        )
    }
}
