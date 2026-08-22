import 'dart:convert';

import '../../../models/competition_capability_profile.dart';
import '../../../models/competition_action_draft.dart';
import '../../campus_data/storage/personal_snapshot_models.dart';
import '../skills/academic_overview_skill.dart';
import '../skills/competition_search_skill.dart';
import '../skills/competition_advisor_skills.dart';
import '../skills/erke_overview_skill.dart';
import '../skills/deterministic_skills.dart';
import '../skills/personal_skill.dart';
import '../skills/physical_overview_skill.dart';
import '../skills/schedule_skill_models.dart';
import '../../../models/user_calendar.dart';

class SkillResultSerializer {
  const SkillResultSerializer();

  String serialize(SkillResult<Object?> result) {
    final envelope = <String, dynamic>{
      'status': result.status.name,
      'warnings': result.warnings,
      'contains_personal_data': result.containsPersonalData,
      'evidence': result.evidence
          .map(
            (item) => <String, dynamic>{
              'source': item.source,
              'scope': item.scope,
              if (item.dataType != null)
                'data_type': item.dataType!.storageValue,
              if (item.fetchedAt != null)
                'fetched_at': item.fetchedAt!.toUtc().toIso8601String(),
              if (item.expiresAt != null)
                'expires_at': item.expiresAt!.toUtc().toIso8601String(),
              'is_stale': item.isStale,
            },
          )
          .toList(growable: false),
      if (result.value != null) 'value': _value(result.value),
    };
    return jsonEncode(envelope);
  }

  Object _value(Object? value) => switch (value) {
        TodayScheduleOutput output => <String, dynamic>{
            'date': _date(output.date),
            'courses': output.courses.map(_course).toList(),
            'free_time_slots': output.freeTimeSlots
                .map(
                  (slot) => <String, dynamic>{
                    'start_section': slot.startSection,
                    'end_section': slot.endSection,
                    'time': slot.timeText,
                  },
                )
                .toList(),
            'data_updated_at': _time(output.dataUpdatedAt),
          },
        WeekScheduleOutput output => <String, dynamic>{
            'start': _date(output.start),
            'end': _date(output.end),
            'courses': output.courses.map(_course).toList(),
            'terms_without_start_date': output.termsWithoutStartDate,
            'data_updated_at': _time(output.dataUpdatedAt),
          },
        AcademicOverviewOutput output => <String, dynamic>{
            'acquired_course_count': output.acquiredCourseCount,
            'covered_terms': output.coveredTerms
                .map(
                  (term) => <String, dynamic>{
                    'year': term.year,
                    'semester': term.semester,
                    'course_count': term.courseCount,
                  },
                )
                .toList(),
            'has_raw_academic_overview': output.hasRawAcademicOverview,
            'has_missing_data': output.hasMissingData,
            'data_updated_at': _time(output.dataUpdatedAt),
          },
        PhysicalOverviewOutput output => <String, dynamic>{
            'latest_year': output.latestYear,
            'total_grade': output.totalGrade,
            'total_score': output.totalScore,
            'metrics': output.metrics
                .map(
                  (item) => <String, dynamic>{
                    'name': item.name,
                    'result': item.result,
                    'grade': item.grade,
                    'score': item.score,
                  },
                )
                .toList(),
            'bmi_inputs_available': output.bmiInputsAvailable,
            'data_updated_at': _time(output.dataUpdatedAt),
          },
        ErkeOverviewOutput output => <String, dynamic>{
            'total_score': output.totalScore,
            'categories': output.categories
                .map(
                  (item) => <String, dynamic>{
                    'code': item.code,
                    'name': item.name,
                    'required': item.required,
                    'earned': item.earned,
                    'meets_numerically': item.meetsNumerically,
                  },
                )
                .toList(),
            'recent_activities': output.recentActivities
                .map(
                  (item) => <String, dynamic>{
                    'item': item.item,
                    'score': item.score,
                    'date': item.date,
                    'category': item.category,
                  },
                )
                .toList(),
            'activity_count': output.activityCount,
            'data_updated_at': _time(output.dataUpdatedAt),
          },
        CompetitionSearchOutput output => <String, dynamic>{
            'keyword': output.keyword,
            'total': output.total,
            'items': output.items
                .map(
                  (item) => <String, dynamic>{
                    'id': item.id,
                    'title': item.title,
                    'summary': item.summary,
                    'category': item.category,
                    'school_recognition_status': item.schoolRecognitionStatus,
                    'registration_time': item.registrationTimeText,
                    'official_url': item.officialUrl,
                    'tags': item.tags,
                  },
                )
                .toList(),
            'data_updated_at': _time(output.dataUpdatedAt),
          },
        CompetitionCapabilityProfile output => <String, dynamic>{
            'preference_configured': output.preferenceConfigured,
            'goals': output.goals,
            'verified_award_count': output.verifiedAwardCount,
            'self_reported_award_count': output.selfReportedAwardCount,
            'skill_summary': output.skillSummary
                .map(
                  (item) => <String, dynamic>{
                    'skill': item.value,
                    'verified_count': item.verifiedCount,
                    'self_reported_count': item.selfReportedCount,
                  },
                )
                .toList(),
            'role_summary': output.roleSummary
                .map(
                  (item) => <String, dynamic>{
                    'role': item.value,
                    'verified_count': item.verifiedCount,
                    'self_reported_count': item.selfReportedCount,
                  },
                )
                .toList(),
            'direction_tags': output.directionTags,
            'preferred_roles': output.preferredRoles,
            'weekly_hours': output.weeklyHours,
            'accept_long_term_training': output.acceptLongTermTraining,
          },
        CompetitionMatchExplanationPage output => <String, dynamic>{
            'profile_ready': output.profileReady,
            'preference_configured': output.preferenceConfigured,
            'total': output.total,
            'catalog': <String, dynamic>{
              'dataset_version': output.catalog.datasetVersion,
              'mode': output.catalog.mode,
              'personalized_ranking_allowed':
                  output.catalog.personalizedRankingAllowed,
            },
            'items': output.items
                .map((item) => <String, dynamic>{
                      'id': item.id,
                      'title': item.title,
                      'group_key': item.groupKey,
                      'rule_order': item.ruleOrder,
                      'has_pending_information': item.hasPendingInformation,
                      'match_dimensions': <String, dynamic>{
                        'eligibility': item.matchDimensions.eligibility,
                        'major': item.matchDimensions.major,
                        'college': item.matchDimensions.college,
                        'grade': item.matchDimensions.grade,
                        'goal': item.matchDimensions.goal,
                        'direction': item.matchDimensions.direction,
                        'skill': item.matchDimensions.skill,
                        'role': item.matchDimensions.role,
                        'time': item.matchDimensions.time,
                        'training': item.matchDimensions.training,
                      },
                      'core_reason': item.coreReason,
                      'cautions': item.cautions,
                      'questions_to_confirm': item.questionsToConfirm,
                      'evidence_subgrade': item.evidenceSubgrade,
                      'dataset_version': item.datasetVersion,
                      'competition_rating': item.competitionRating,
                      'school_recognition_status': item.schoolRecognitionStatus,
                      'school_recognition_grade': item.schoolRecognitionGrade,
                      'time_status': item.timeStatus,
                      'registration_time_text': item.registrationTimeText,
                    })
                .toList(),
            'data_updated_at': _time(output.fetchedAt),
          },
        CompetitionPlanActionDraft output => <String, dynamic>{
            'draft_id': output.id,
            'action_type': output.actionType,
            'status': output.status,
            'expires_at': output.expiresAt.toUtc().toIso8601String(),
            'event': output.toJson()['event'],
            'confirmation_required': true,
            'warnings': const <String>[
              '这是待确认草稿，确认时服务端会重新校验',
              '不会自动报名，也不代表学校确认参赛资格或政策收益',
            ],
          },
        UserCalendarActionDraft output => <String, dynamic>{
            'draft_id': output.id,
            'action_type': output.actionType,
            'status': output.status,
            'title': output.title,
            'description': output.description,
            'start_at': output.startAt.toUtc().toIso8601String(),
            'end_at': output.endAt.toUtc().toIso8601String(),
            'all_day': output.allDay,
            'location': output.location,
            'timezone': output.timezone,
            if (output.targetEventId != null)
              'target_event_id': output.targetEventId,
            if (output.reminderMinutesBefore != null)
              'reminder_minutes_before': output.reminderMinutesBefore,
            'expires_at': output.expiresAt.toUtc().toIso8601String(),
            'confirmation_required': true,
            'warnings': const <String>[
              '这是待确认草稿，确认后服务端才会执行日历操作',
              '删除和加提醒同样需要用户确认',
            ],
          },
        AcademicGpaOutput output => <String, dynamic>{
            'formula_version': output.result.formulaVersion,
            'gpa': output.result.gpa,
            'included_credits': output.result.includedCredits,
            'included_courses': output.result.includedCourses
                .map(
                  (item) => <String, dynamic>{
                    'course_name': item.courseName,
                    'semester_id': item.semesterId,
                    'credit': item.credit,
                    'reason': item.reason,
                  },
                )
                .toList(),
            'excluded_courses': output.result.excludedCourses
                .map(
                  (item) => <String, dynamic>{
                    'course_name': item.courseName,
                    'reason': item.reason,
                  },
                )
                .toList(),
            'unparseable_courses': output.result.unparseableCourses,
            'missing_credit_count': output.result.missingCreditCount,
          },
        AcademicCreditOutput output => <String, dynamic>{
            'attempted_credits': output.summary.attemptedCredits,
            'passed_credits': output.summary.passedCredits,
            'failed_credits': output.summary.failedCredits,
            'required_failed_credits': output.summary.requiredFailedCredits,
            'unknown_credits': output.summary.unknownCredits,
          },
        AcademicFailureRiskOutput output => <String, dynamic>{
            'failed_courses': output.summary.failedCourses
                .map(
                  (item) => <String, dynamic>{
                    'course_name': item.courseName,
                    'credit': item.credit,
                    'nature': item.nature.name,
                  },
                )
                .toList(),
            'unknown_courses': output.summary.unknownCourses
                .map((item) => item.courseName)
                .toList(),
          },
        GraduationReadinessOutput output => <String, dynamic>{
            'policy_id': output.readiness.policyId,
            'requirements': output.readiness.items
                .map(
                  (item) => <String, dynamic>{
                    'id': item.id,
                    'label': item.label,
                    'state': item.state.name,
                    'summary': item.summary,
                  },
                )
                .toList(),
            'warnings': output.readiness.warnings,
          },
        FitnessWeeklyPlanOutput output => <String, dynamic>{
            'bmi': output.plan.bmi,
            'bmi_version': output.plan.bmiVersion,
            'sessions': output.plan.sessions
                .map(
                  (item) => <String, dynamic>{
                    'start': item.start.toUtc().toIso8601String(),
                    'minutes': item.minutes,
                    'intensity': item.intensity.name,
                  },
                )
                .toList(),
            'safety_notes': output.plan.safetyNotes,
          },
        _ => throw const FormatException('Skill 输出类型未注册'),
      };

  Map<String, dynamic> _course(ScheduleSkillCourse item) => <String, dynamic>{
        'date': _date(item.date),
        'course_name': item.courseName,
        'start_section': item.startSection,
        'end_section': item.endSection,
        'time': item.timeText,
        if (item.teacher != null) 'teacher': item.teacher,
        if (item.location != null) 'location': item.location,
      };

  String _date(DateTime value) => value.toIso8601String().substring(0, 10);
  String? _time(DateTime? value) => value?.toUtc().toIso8601String();
}
