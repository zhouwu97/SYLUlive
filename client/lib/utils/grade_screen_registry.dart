abstract class GradeScreenLinkTarget {
  bool get canHandleGradeLink;

  Future<bool> switchToGradeSemester(String year, int semester);
}

class GradeScreenRegistry {
  GradeScreenRegistry._();

  static GradeScreenLinkTarget? _target;

  static void register(GradeScreenLinkTarget target) {
    _target = target;
  }

  static void unregister(GradeScreenLinkTarget target) {
    if (identical(_target, target)) {
      _target = null;
    }
  }

  static Future<bool> trySwitch(String year, int semester) async {
    final target = _target;
    if (target == null || !target.canHandleGradeLink) return false;
    return target.switchToGradeSemester(year, semester);
  }
}
