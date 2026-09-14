/// 课表周次文案格式化器（WeekFormatter）
///
/// 统一处理课程周次的易读展示，避免各页面自行 first-last 导致非连续周显示错误。
class WeekFormatter {
  const WeekFormatter._();

  /// 格式化周次列表为统一文案
  ///
  /// 示例：
  /// - `[]` -> "全周"
  /// - `[3]` -> "3周" 或 "第3周" (prefixWithDi: true)
  /// - `[1, 2, 3, 4, 5]` -> "1-5周"
  /// - `[1, 3, 5, 7]` -> "1-7周（单）"
  /// - `[2, 4, 6, 8]` -> "2-8周（双）"
  /// - `[1, 3, 5]` -> "1、3、5周"
  /// - `[1, 2, 3, 6, 7]` -> "1-3、6-7周"
  static String format(
    Iterable<int> weeks, {
    bool prefixWithDi = false,
  }) {
    final list = weeks.where((w) => w > 0).toSet().toList()..sort();
    if (list.isEmpty) return '全周';

    if (list.length == 1) {
      return prefixWithDi ? '第${list.first}周' : '${list.first}周';
    }

    final min = list.first;
    final max = list.last;

    // 1. 连续周次
    var isConsecutive = true;
    for (var i = 0; i < list.length; i++) {
      if (list[i] != min + i) {
        isConsecutive = false;
        break;
      }
    }
    if (isConsecutive) {
      final text = '$min-$max周';
      return prefixWithDi ? '第$text' : text;
    }

    // 2. 纯单周 (全部为奇数且无空隙)
    final allOdd = list.every((w) => w.isOdd);
    if (allOdd) {
      final expectedOddCount = ((max - min) ~/ 2) + 1;
      if (list.length == expectedOddCount && expectedOddCount > 1) {
        final text = '$min-$max周（单）';
        return prefixWithDi ? '第$text' : text;
      }
    }

    // 3. 纯双周 (全部为偶数且无空隙)
    final allEven = list.every((w) => w.isEven);
    if (allEven) {
      final expectedEvenCount = ((max - min) ~/ 2) + 1;
      if (list.length == expectedEvenCount && expectedEvenCount > 1) {
        final text = '$min-$max周（双）';
        return prefixWithDi ? '第$text' : text;
      }
    }

    // 4. 离散周次较少时，直接使用顿号连接
    if (list.length <= 4) {
      final text = '${list.join('、')}周';
      return prefixWithDi ? '第$text' : text;
    }

    // 5. 分段连续区间归并
    final ranges = <String>[];
    var start = list.first;
    var prev = list.first;

    for (var i = 1; i < list.length; i++) {
      final curr = list[i];
      if (curr == prev + 1) {
        prev = curr;
      } else {
        ranges.add(start == prev ? '$start' : '$start-$prev');
        start = curr;
        prev = curr;
      }
    }
    ranges.add(start == prev ? '$start' : '$start-$prev');

    final text = '${ranges.join('、')}周';
    return prefixWithDi ? '第$text' : text;
  }
}
