class PrivilegedAccounts {
  static const unlimitedImageStudentId = '[REDACTED_STUDENT_ID]';
  static const oneClassOrdersStudentId = '[REDACTED_STUDENT_ID]';

  static bool canUploadUnlimitedImages(String? studentId) {
    return studentId == unlimitedImageStudentId;
  }

  static bool canViewOneClassOrders(String? studentId) {
    return studentId == oneClassOrdersStudentId;
  }
}
