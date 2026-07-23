abstract interface class ReminderScheduler {
  Future<void> schedule(String identifier, DateTime time, String payload);
  Future<void> cancel(String identifier);
}
