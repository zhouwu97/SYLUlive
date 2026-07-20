import 'personal_snapshot_file_backend_base.dart';
import 'personal_snapshot_file_backend_stub.dart'
    if (dart.library.io) 'personal_snapshot_file_backend_io.dart'
    as platform;

PersonalSnapshotFileBackend createPersonalSnapshotFileBackend() {
  return platform.createPersonalSnapshotFileBackend();
}
