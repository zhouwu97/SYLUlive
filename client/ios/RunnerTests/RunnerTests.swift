import Foundation
import XCTest

class RunnerTests: XCTestCase {
  private var suiteName: String!
  private var defaults: UserDefaults!
  private var calendar: Calendar!

  override func setUp() {
    super.setUp()
    suiteName = "widget-tests-\(UUID().uuidString)"
    defaults = UserDefaults(suiteName: suiteName)!
    calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
  }

  override func tearDown() {
    defaults.removePersistentDomain(forName: suiteName)
    super.tearDown()
  }

  private func date(_ value: String) -> Date {
    let formatter = DateFormatter()
    formatter.calendar = calendar
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = calendar.timeZone
    formatter.dateFormat = "yyyy-MM-dd HH:mm"
    return formatter.date(from: value)!
  }

  private func save(_ payload: [String: Any]) throws {
    let bytes = try JSONSerialization.data(withJSONObject: payload)
    HomeWidgetSharedStore.write([
      "course_data": String(data: bytes, encoding: .utf8)!,
    ], to: defaults)
  }

  private func course(_ name: String, weekday: Int, weeks: [Int], start: Int = 1) -> [String: Any] {
    ["name": name, "weekday": weekday, "weeks": weeks,
     "start_section": start, "end_section": start + 1,
     "location": "测试教室", "color": "#123456"]
  }

  func testSharedWriteReadAndExplicitNullClearing() throws {
    try save(["schema_version": 2, "semester_start": "2026-11-23", "courses": [
      course("真实课程", weekday: 4, weeks: [1]),
    ]])
    HomeWidgetSharedStore.write([
      "exam_data": "考试数据", "course_title": "我的课表",
      "course_theme": "appTheme", "course_frosted_glass": true,
    ], to: defaults)
    defaults.synchronize()
    let extensionDefaults = UserDefaults(suiteName: suiteName)!
    let now = date("2026-11-26 09:00")
    let entry = HomeWidgetCourseData.read(defaults: extensionDefaults, now: now, calendar: calendar)
    XCTAssertEqual(entry.courses.map { $0.name }, ["真实课程"])
    XCTAssertEqual(entry.title, "我的课表")
    XCTAssertTrue(extensionDefaults.bool(forKey: "widget_course_frosted_glass"))

    HomeWidgetSharedStore.write(["course_theme": "system"], to: defaults)
    XCTAssertNotNil(defaults.string(forKey: "widget_course_data"))
    HomeWidgetSharedStore.write(["course_data": NSNull(), "exam_data": NSNull()], to: defaults)
    defaults.synchronize()
    XCTAssertNil(extensionDefaults.string(forKey: "widget_course_data"))
    XCTAssertNil(extensionDefaults.string(forKey: "widget_exam_data"))
    XCTAssertEqual(HomeWidgetCourseData.read(defaults: extensionDefaults, now: now,
      calendar: calendar).dateInfo, "尚未同步")
  }

  func testDiscreteWeeksAndSectionOrder() throws {
    try save(["schema_version": 2, "semester_start": "2026-11-16", "courses": [
      course("后面的课", weekday: 4, weeks: [2], start: 5),
      course("其他周", weekday: 4, weeks: [1, 3]),
      course("前面的课", weekday: 4, weeks: [2]),
      course("其他天", weekday: 3, weeks: [2]),
    ]])
    let entry = HomeWidgetCourseData.read(defaults: defaults, now: date("2026-11-26 09:00"), calendar: calendar)
    XCTAssertEqual(entry.courses.map { $0.name }, ["前面的课", "后面的课"])
    XCTAssertEqual(entry.courses.map { $0.time }, ["08:00-09:40", "13:00-14:40"])
    XCTAssertEqual(entry.dateInfo, "11.26 第2周 周四")
  }

  func testSundayAndFollowingMondayUseDifferentAcademicWeeks() throws {
    try save(["schema_version": 2, "semester_start": "2026-11-23", "courses": [
      course("周日课", weekday: 7, weeks: [1]),
      course("下周一课", weekday: 1, weeks: [2]),
      course("上周一课", weekday: 1, weeks: [1]),
    ]])
    let entries = HomeWidgetCourseData.timelineDates(now: date("2026-11-29 23:59"), calendar: calendar)
      .map { HomeWidgetCourseData.read(defaults: defaults, now: $0, calendar: calendar) }
    XCTAssertEqual(entries.count, 8)
    XCTAssertEqual(entries[0].courses.map { $0.name }, ["周日课"])
    XCTAssertEqual(entries[1].courses.map { $0.name }, ["下周一课"])
    XCTAssertEqual(entries[1].date, date("2026-11-30 00:00"))
    XCTAssertEqual(entries.last!.date, date("2026-12-06 00:00"))
  }

  func testFutureSemesterAndEmptyDayAreDistinct() throws {
    try save(["schema_version": 2, "semester_start": "2026-12-07", "courses": [
      course("尚未开学的课", weekday: 4, weeks: [1]),
    ]])
    let before = HomeWidgetCourseData.read(defaults: defaults, now: date("2026-11-26 09:00"), calendar: calendar)
    XCTAssertTrue(before.isEmpty)
    XCTAssertEqual(before.dateInfo, "尚未开学")
    let after = HomeWidgetCourseData.read(defaults: defaults, now: date("2026-12-09 09:00"), calendar: calendar)
    XCTAssertTrue(after.isEmpty)
    XCTAssertEqual(after.emptyMessage, "今天没有课啦")
  }

  func testNoSemesterStartRetainsWeekdayOnlyCompatibility() throws {
    try save(["schema_version": 2, "courses": [course("周四课", weekday: 4, weeks: [1])]])
    let entry = HomeWidgetCourseData.read(defaults: defaults, now: date("2026-11-26 09:00"), calendar: calendar)
    XCTAssertEqual(entry.courses.map { $0.name }, ["周四课"])
  }

  func testNonGregorianDeviceCalendarStillUsesGregorianSemesterDates() throws {
    try save(["schema_version": 2, "semester_start": "2026-11-23", "courses": [
      course("真实课程", weekday: 4, weeks: [1]),
    ]])
    var buddhist = Calendar(identifier: .buddhist)
    buddhist.timeZone = calendar.timeZone
    let entry = HomeWidgetCourseData.read(defaults: defaults, now: date("2026-11-26 09:00"), calendar: buddhist)
    XCTAssertEqual(entry.courses.map { $0.name }, ["真实课程"])
    XCTAssertEqual(entry.dateInfo, "11.26 第1周 周四")
  }

  func testLegacyDailyPayloadDoesNotPersistIntoTomorrow() throws {
    try save(["schema_version": 1, "date_key": "2026-11-26", "date": "今日", "courses": [
      ["name": "旧格式课程", "time": "08:00-09:40"],
    ]])
    for (day, count) in [("2026-11-26 23:59", 1), ("2026-11-27 00:00", 0)] {
      let entry = HomeWidgetCourseData.read(defaults: defaults, now: date(day), calendar: calendar)
      XCTAssertEqual(entry.courses.count, count)
    }
  }

  func testMissingGroupUnsyncedAndInvalidDataAreDistinct() throws {
    let now = date("2026-11-26 09:00")
    XCTAssertEqual(HomeWidgetCourseData.read(defaults: nil, now: now).dateInfo, "共享存储不可用")
    XCTAssertEqual(HomeWidgetCourseData.read(defaults: defaults, now: now).dateInfo, "尚未同步")
    defaults.set("invalid-json", forKey: "widget_course_data")
    XCTAssertEqual(HomeWidgetCourseData.read(defaults: defaults, now: now).dateInfo, "课表读取失败")
    try save(["schema_version": 99, "courses": []])
    XCTAssertEqual(HomeWidgetCourseData.read(defaults: defaults, now: now).dateInfo, "课表格式需更新")
  }
}
