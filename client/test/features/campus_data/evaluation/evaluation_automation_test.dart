import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/features/campus_data/evaluation/evaluation_scripts/evaluation_save_script.dart';
import 'package:shenliyuan/features/campus_data/evaluation/evaluation_scripts/evaluation_navigation_script.dart';
import 'package:shenliyuan/features/campus_data/evaluation/evaluation_scripts/evaluation_list_script.dart';
import 'package:shenliyuan/features/campus_data/evaluation/evaluation_script_builder.dart';

void main() {
  group('Evaluation Automation Security & Logic Tests', () {
    test('All automation scripts must strictly forbid submit actions', () {
      final scripts = [
        buildSaveCurrentScript(),
        buildSaveSnapshotScript(),
        buildGetEvaluationListScript(),
        buildSelectNextPendingScript('row_id'),
        buildGoToNextPageScript(),
        buildFillScript(),
        buildProbeScript(),
      ];

      for (var i = 0; i < scripts.length; i++) {
        final script = scripts[i];
        
        // 1. Must not explicitly call .submit() on any form
        expect(script.contains(RegExp(r'\.submit\(\)')), isFalse, reason: 'Script #$i contains .submit()');
        
        // 2. Must not explicitly call .requestSubmit()
        expect(script.contains(RegExp(r'\.requestSubmit\(\)')), isFalse, reason: 'Script #$i contains .requestSubmit()');
        
        // 3. Must not query and click submit buttons directly by type="submit" without checking value
        // The save script queries them, BUT it filters them. We should verify it doesn't just do `querySelector('input[type="submit"]').click()`
        expect(script.contains(RegExp(r'querySelector\([^)]*type=["\']submit["\'][^)]*\)\.click\(\)')), isFalse, reason: 'Script #$i directly clicks submit query selector');
      }
    });

    test('Save script contains isSubmitAction checks', () {
      final saveScript = buildSaveCurrentScript();
      expect(saveScript, contains('isSubmitAction'));
      expect(saveScript, contains("if (text.indexOf('提交') >= 0) return true;"));
      expect(saveScript, contains("if (text === '保存') {"));
    });

    test('Fill script does not use redundant blur events', () {
      final fillScript = buildFillScript();
      // Should contain input and change
      expect(fillScript, contains("new Event('input'"));
      expect(fillScript, contains("new Event('change'"));
      
      // Should NOT contain a blanket blur event for all inputs inside the loop
      // (We removed the blur event from the main fill loop)
      final blurCount = RegExp(r"new Event\('blur'").allMatches(fillScript).length;
      expect(blurCount, 0, reason: 'Should not fire blur on every input individually');
    });
  });
}
