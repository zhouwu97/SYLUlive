class PrivilegedAccounts {
  static const unlimitedImageStudentId = '2403060128';
  static const oneClassOrdersStudentId = '2403060128';

  static bool canUploadUnlimitedImages(String? studentId) {
    return studentId == unlimitedImageStudentId;
  }

  static bool canViewOneClassOrders(String? studentId) {
    return studentId == oneClassOrdersStudentId;
  }
}
