import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/screens/grade_refresh_policy.dart';

void main() {
  const freshFor = Duration(minutes: 15);
  const backoff = Duration(minutes: 2);
  final now = DateTime(2026, 9, 19, 12, 0, 0);

  group('decideGradeLoad —— 计划 8.3 自动刷新决策表', () {
    test('GRADE-01 新鲜缓存 + 最近失败：显示缓存且不请求', () {
      // 这是 [E04] 的原始缺陷：原实现要求「不在退避期」才使用缓存，
      // 于是这一行会落到后台刷新分支，在退避期内照样发请求。
      final decision = decideGradeLoad(
        hasCredibleCache: true,
        isFresh: true,
        inFailureBackoff: true,
        userInitiated: false,
      );
      expect(decision, GradeLoadDecision.cacheOnly);
    });

    test('新鲜缓存且不在退避期：显示缓存且不请求', () {
      expect(
        decideGradeLoad(
          hasCredibleCache: true,
          isFresh: true,
          inFailureBackoff: false,
          userInitiated: false,
        ),
        GradeLoadDecision.cacheOnly,
      );
    });

    test('GRADE-02 过期缓存 + 退避期内（自动/resume）：显示旧结果，不自动请求', () {
      expect(
        decideGradeLoad(
          hasCredibleCache: true,
          isFresh: false,
          inFailureBackoff: true,
          userInitiated: false,
        ),
        GradeLoadDecision.cacheOnly,
      );
    });

    test('GRADE-02 过期缓存 + 退避到期：显示缓存并至多启动一次后台刷新', () {
      expect(
        decideGradeLoad(
          hasCredibleCache: true,
          isFresh: false,
          inFailureBackoff: false,
          userInitiated: false,
        ),
        GradeLoadDecision.cacheThenRefresh,
      );
    });

    test('无可信缓存：进入完整加载（失败时才展示错误/重试入口）', () {
      for (final inBackoff in [true, false]) {
        expect(
          decideGradeLoad(
            hasCredibleCache: false,
            isFresh: false,
            inFailureBackoff: inBackoff,
            userInitiated: false,
          ),
          GradeLoadDecision.fullLoad,
        );
      }
    });

    test('用户明确刷新：可绕过时间退避，但仍有缓存时先展示缓存', () {
      expect(
        decideGradeLoad(
          hasCredibleCache: true,
          isFresh: false,
          inFailureBackoff: true,
          userInitiated: true,
        ),
        GradeLoadDecision.cacheThenRefresh,
      );
      expect(
        decideGradeLoad(
          hasCredibleCache: true,
          isFresh: true,
          inFailureBackoff: false,
          userInitiated: true,
        ),
        GradeLoadDecision.cacheThenRefresh,
      );
    });
  });

  group('gradeCacheIsFresh / gradeInFailureBackoff 边界', () {
    test('恰好等于新鲜期仍算新鲜，超过则不再新鲜', () {
      expect(
        gradeCacheIsFresh(updatedAt: now.subtract(freshFor), now: now, freshFor: freshFor),
        isTrue,
      );
      expect(
        gradeCacheIsFresh(
          updatedAt: now.subtract(freshFor + const Duration(seconds: 1)),
          now: now,
          freshFor: freshFor,
        ),
        isFalse,
      );
    });

    test('没有失败记录时不在退避期', () {
      expect(
        gradeInFailureBackoff(lastFailureAt: null, now: now, backoff: backoff),
        isFalse,
      );
    });

    test('退避期内为真，超过退避期后为假', () {
      expect(
        gradeInFailureBackoff(
          lastFailureAt: now.subtract(backoff - const Duration(seconds: 1)),
          now: now,
          backoff: backoff,
        ),
        isTrue,
      );
      expect(
        gradeInFailureBackoff(
          lastFailureAt: now.subtract(backoff + const Duration(seconds: 1)),
          now: now,
          backoff: backoff,
        ),
        isFalse,
      );
    });
  });

  group('allowsInteractiveAcademicLogin / gradeOriginIsSilent —— 谁能打断用户（计划 8.2）', () {
    test('A07 只有首次进入和用户明确刷新允许弹教务登录框', () {
      // 首次进入且没有可信缓存：此时没有可展示的旧结果，只能进登录流程。
      expect(
          allowsInteractiveAcademicLogin(GradeRefreshOrigin.initial,
              hasCredibleCache: false),
          isTrue);
      expect(allowsInteractiveAcademicLogin(GradeRefreshOrigin.manual), isTrue);
      // 自动刷新与前台恢复是「顺带」发生的，没有表达过要重新输入的意愿。
      expect(
          allowsInteractiveAcademicLogin(GradeRefreshOrigin.automatic), isFalse);
      expect(allowsInteractiveAcademicLogin(GradeRefreshOrigin.resume), isFalse);
      // 会话刚恢复可信后的补读：用户已经在登录流程里，不该再弹一次。
      expect(allowsInteractiveAcademicLogin(GradeRefreshOrigin.sessionRecovered),
          isFalse);
    });

    test('有可信缓存时不把人从已展示的成绩里拽进登录流程', () {
      // 本机有过期成绩 -> 首次进入成绩页 -> 学校会话过期需要人工凭据。
      // 此时应当先展示缓存，再给「重新连接以更新」的入口。
      expect(
          allowsInteractiveAcademicLogin(GradeRefreshOrigin.initial,
              hasCredibleCache: true),
          isFalse);
      // 用户明确点更新时仍然允许打断——他是来拿新数据的。
      expect(
          allowsInteractiveAcademicLogin(GradeRefreshOrigin.manual,
              hasCredibleCache: true),
          isTrue);
    });

    test('A07 交互登录权限与「是否静默」不是同一维度', () {
      // sessionRecovered 不静默（成功提示、减少确认照旧），但不允许弹框；
      // 反过来 manual 既不静默也允许弹框。二者不能互相推导。
      expect(gradeOriginIsSilent(GradeRefreshOrigin.sessionRecovered), isFalse);
      expect(allowsInteractiveAcademicLogin(GradeRefreshOrigin.sessionRecovered),
          isFalse);
      expect(gradeOriginIsSilent(GradeRefreshOrigin.manual), isFalse);
      expect(allowsInteractiveAcademicLogin(GradeRefreshOrigin.manual,
          hasCredibleCache: true), isTrue);
    });

    test('自动与前台恢复属于静默来源，手动与首屏属于非静默来源', () {
      expect(gradeOriginIsSilent(GradeRefreshOrigin.automatic), isTrue);
      expect(gradeOriginIsSilent(GradeRefreshOrigin.resume), isTrue);
      expect(gradeOriginIsSilent(GradeRefreshOrigin.initial), isFalse);
      expect(gradeOriginIsSilent(GradeRefreshOrigin.manual), isFalse);
    });
  });

  group('allowReducedGradeOverwrite —— 权限不得顺带授予（计划 8.2）', () {
    test('自动/前台恢复（silent）永远不允许覆盖可信基线', () {
      // 即使别处传了 forceRefresh=true，静默刷新也不能确认减少。
      expect(
        allowReducedGradeOverwrite(
          silent: true,
          userConfirmedReduction: true,
        ),
        isFalse,
      );
    });

    test('非静默但没有用户确认时也不允许', () {
      expect(
        allowReducedGradeOverwrite(
          silent: false,
          userConfirmedReduction: false,
        ),
        isFalse,
      );
    });

    test('非静默且用户已确认时才允许', () {
      expect(
        allowReducedGradeOverwrite(
          silent: false,
          userConfirmedReduction: true,
        ),
        isTrue,
      );
    });
  });

  group('GradeReductionConfirmation —— 减少确认的作用域 / 候选绑定 / 一次性语义（计划 8.5）', () {
    const scope = '1001|2403130233|2025|1';
    const nineteenGrades = '19#A,B,C';
    const zeroGrades = '0#';

    test('首次提示不授予确认，第二次才消费成功，且只能消费一次', () {
      final confirmation = GradeReductionConfirmation();
      expect(confirmation.hasPendingWarning, isFalse);
      // 首次遇到减少：只提示。
      confirmation.warn(scope, nineteenGrades);
      expect(confirmation.hasPendingWarning, isTrue);
      // 用户再次明确刷新 → 确认生效，并交回候选指纹供与实际结果比对。
      expect(confirmation.consume(scope), nineteenGrades);
      // 已经消费过，不能重复授予。
      expect(confirmation.consume(scope), isNull);
      expect(confirmation.hasPendingWarning, isFalse);
    });

    test('GRADE-06 确认期间切学期：旧确认不能作用到新上下文', () {
      final confirmation = GradeReductionConfirmation();
      confirmation.warn(scope, nineteenGrades);
      // 切到另一个学期后才发起刷新。
      expect(confirmation.consume('1001|2403130233|2025|2'), isNull);
    });

    test('GRADE-06 确认期间切号：旧确认作废', () {
      final confirmation = GradeReductionConfirmation();
      confirmation.warn(scope, nineteenGrades);
      expect(confirmation.consume('2002|2403130233|2025|1'), isNull);
    });

    test('确认期间切换教务身份（本科→研究生）同样作废', () {
      final confirmation = GradeReductionConfirmation();
      confirmation.warn('1001|sylu_undergraduate:2403130233|2025|1', nineteenGrades);
      expect(confirmation.consume('1001|sylu_graduate:G-001|2025|1'), isNull);
    });

    test('reset 后未消费的提示被废弃', () {
      final confirmation = GradeReductionConfirmation();
      confirmation.warn(scope, nineteenGrades);
      confirmation.reset();
      expect(confirmation.hasPendingWarning, isFalse);
      expect(confirmation.consume(scope), isNull);
    });

    test('GRADE-07 确认绑定具体候选：20→19 的确认不得授权 19→0', () {
      final confirmation = GradeReductionConfirmation();
      // 第一次减少：20 门 -> 19 门，记录这份候选。
      confirmation.warn(scope, nineteenGrades);
      // 用户再次刷新，取回确认。
      final confirmed = confirmation.consume(scope);
      expect(confirmed, nineteenGrades);
      // 但本次实际返回 0 门，与确认过的候选不一致 → 不能凭旧确认覆盖。
      expect(confirmed == zeroGrades, isFalse);
    });

    test('重新提示后候选指纹随之更新，旧指纹不再被承认', () {
      final confirmation = GradeReductionConfirmation();
      confirmation.warn(scope, nineteenGrades);
      // 结果再次变化：页面用新候选重新提示。
      confirmation.warn(scope, zeroGrades);
      expect(confirmation.consume(scope), zeroGrades);
      expect(confirmation.consume(scope), isNull);
    });
  });
}
