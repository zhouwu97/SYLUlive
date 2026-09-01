import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:jiaowu_dart_poc/jiaowu_dart.dart';

Future<void> main(List<String> arguments) async {
  final parser = ArgParser()
    ..addOption(
      'action',
      defaultsTo: 'all',
      allowed: ['login', 'profile', 'courses', 'grades', 'all'],
      help: '执行范围：login、profile、courses、grades 或 all',
    )
    ..addOption('student-id', help: '学号；也可使用 JIAOWU_STUDENT_ID')
    ..addOption(
      'password',
      help: '密码；也可使用 JIAOWU_PASSWORD（更推荐环境变量）',
    )
    ..addOption(
      'base-url',
      defaultsTo: JiaowuEndpoints.defaultBaseUrl,
      help: '仅用于本地协议 Mock 或测试环境',
    )
    ..addOption('year', help: '课表学年，例如 2026')
    ..addOption('semester', help: '课表学期，例如 3')
    ..addFlag(
      'json',
      negatable: false,
      help: '课程或成绩成功后额外输出 canonical JSON',
    )
    ..addFlag('help', abbr: 'h', negatable: false);

  final options = parser.parse(arguments);
  if (options['help'] as bool) {
    stdout.writeln(parser.usage);
    return;
  }

  final action = options['action'] as String;
  final year = options['year'] as String?;
  final semesterText = options['semester'] as String?;
  final hasYear = year != null && year.isNotEmpty;
  final hasSemester = semesterText != null && semesterText.isNotEmpty;
  if (hasYear != hasSemester ||
      ((action == 'courses' || action == 'grades') &&
          !(hasYear && hasSemester)) ||
      (hasYear &&
          action != 'courses' &&
          action != 'grades' &&
          action != 'all') ||
      ((options['json'] as bool) &&
          action != 'courses' &&
          action != 'grades' &&
          !(action == 'all' && hasYear && hasSemester))) {
    stderr.writeln(
      '--year、--semester 和 --json 仅用于 courses/grades，'
      'all 需要同时提供课表参数。',
    );
    exitCode = 64;
    return;
  }

  int? semester;
  if (hasSemester) {
    semester = int.tryParse(semesterText);
    if (semester == null) {
      stderr.writeln('--semester 必须是整数。');
      exitCode = 64;
      return;
    }
  }
  if (hasYear) {
    try {
      JiaowuRequestValidator.validateAcademicRequest(
        year: year,
        semester: semester!,
      );
    } on ArgumentError catch (error) {
      stderr.writeln(error.message);
      exitCode = 64;
      return;
    }
  }

  final studentId = (options['student-id'] as String?) ??
      Platform.environment['JIAOWU_STUDENT_ID'];
  final password = (options['password'] as String?) ??
      Platform.environment['JIAOWU_PASSWORD'];
  if (studentId == null || studentId.isEmpty || password == null) {
    stderr.writeln(
      '缺少凭据。请设置 JIAOWU_STUDENT_ID / JIAOWU_PASSWORD，'
      '或通过参数传入。',
    );
    exitCode = 64;
    return;
  }

  final client = JiaowuClient(baseUrl: options['base-url'] as String);
  try {
    stdout.writeln('SYLU Jiaowu Dart Probe');
    final result = await client.login(
      studentId: studentId,
      password: password,
    );
    switch (result) {
      case LoginSuccess(:final cookieNames):
        stdout.writeln('[LOGIN] OK');
        stdout.writeln('cookies = ${cookieNames.toList()..sort()}');
      case InvalidCredentials(:final message):
        stdout.writeln('[LOGIN] FAIL: $message');
        exitCode = 1;
      case CaptchaRequired(:final message):
        stdout.writeln('[LOGIN] CAPTCHA: $message');
        exitCode = 2;
      case LoginPageChanged(:final message):
        stdout.writeln('[LOGIN] PROTOCOL: $message');
        exitCode = 3;
      case NetworkUnavailable(:final message):
        stdout.writeln('[LOGIN] NETWORK: $message');
        exitCode = 4;
    }

    if (result is LoginSuccess) {
      if (action == 'profile' || action == 'all') {
        final profile = await client.getProfile();
        stdout.writeln('[PROFILE] OK');
        stdout.writeln('name = ${_mask(profile.name)}');
        stdout.writeln('grade = ${profile.grade}');
        stdout.writeln('college = ${_mask(profile.college)}');
        stdout.writeln('major = ${_mask(profile.major)}');
      }

      final shouldFetchCourses =
          action == 'courses' || (action == 'all' && hasYear && hasSemester);
      if (shouldFetchCourses) {
        try {
          final courses = await client.getCourses(
            year: year!,
            semester: semester!,
          );
          stdout.writeln('[COURSES] OK');
          stdout.writeln('source = ${courses.source.name}');
          stdout.writeln('records = ${courses.courses.length}');
          if (options['json'] as bool) {
            stdout.writeln(jsonEncode(courses.canonicalJson));
          }
        } on CourseNotOpenException {
          stdout.writeln('[COURSES] EMPTY');
          stdout.writeln('records = 0');
          if (options['json'] as bool) stdout.writeln('[]');
        }
      }

      if (action == 'grades') {
        final grades = await client.getGrades(
          year: year!,
          semester: semester!,
        );
        stdout.writeln(grades.validEmpty ? '[GRADES] EMPTY' : '[GRADES] OK');
        stdout.writeln('records = ${grades.grades.length}');
        stdout.writeln('pages = ${grades.pages}');
        if (options['json'] as bool) {
          stdout.writeln(jsonEncode(grades.canonicalJson));
        }
      }
    }
  } on JiaowuException catch (error) {
    stdout.writeln('[ERROR] ${error.code}: ${error.message}');
    exitCode = 5;
  } finally {
    client.close(force: true);
  }
}

String _mask(String value) {
  if (value.length <= 1) return '*';
  if (value.length == 2) return '${value[0]}*';
  return '${value[0]}${'*' * (value.length - 2)}${value[value.length - 1]}';
}
