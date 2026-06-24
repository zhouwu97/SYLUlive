/// Centralized JavaScript scripts for the evaluation WebView.
library;

/// Builds the page-probe JavaScript string (READ-ONLY).
String buildProbeScript() {
  return r'''
(function () {
  'use strict';
  try {
    var MAX_TEXT_LENGTH = 120;
    var MAX_TEXT_SAMPLE = 300;

    function safeStr(s) {
      if (s == null) return '';
      return String(s).substring(0, MAX_TEXT_LENGTH);
    }

    function safeText(n) {
      if (!n) return '';
      var t = (n.textContent || '').replace(/\s+/g, ' ').trim();
      return t.substring(0, MAX_TEXT_LENGTH);
    }

    // ── Full-body boolean text detection (no full body returned) ──
    var fullBody = '';
    try { fullBody = (document.body ? document.body.textContent || '' : ''); } catch(e){}

    function bodyContainsAny(patterns) {
      for (var i = 0; i < patterns.length; i++) {
        if (fullBody.indexOf(patterns[i]) >= 0) return true;
      }
      return false;
    }

    var hasSubmittedText = bodyContainsAny([
      '提交成功','评价成功','保存成功','操作成功','感谢您的评价','评教完成'
    ]);
    var hasSessionExpiredText = bodyContainsAny([
      '会话已过期','session expired','请重新登录','登录超时','未登录','用户未登录'
    ]);
    var hasAccessDeniedText = bodyContainsAny([
      '无权限','禁止访问','403','access denied','forbidden'
    ]);
    var hasMaintenanceText = bodyContainsAny([
      '系统维护','正在维护','暂未开放','系统升级'
    ]);
    var hasAlreadyEvaluatedText = bodyContainsAny([
      '已评价','已完成','已提交','查看评价'
    ]);

    function collectRadios() {
      var result = [];
      try {
        var radios = document.querySelectorAll('input[type="radio"]');
        for (var i = 0; i < radios.length; i++) {
          try {
            var r = radios[i];
            result.push({
              name: safeStr(r.name),
              id: safeStr(r.id),
              value: safeStr(r.value),
              className: safeStr(r.className),
              data_dyf: safeStr(r.getAttribute('data-dyf')),
              data_score: safeStr(r.getAttribute('data-score')),
              data_fz: safeStr(r.getAttribute('data-fz')),
              checked: !!r.checked,
              disabled: !!r.disabled
            });
          } catch (e) {}
        }
      } catch (e) {}
      return result;
    }

    function collectForms() {
      var result = [];
      try {
        var forms = document.querySelectorAll('form');
        for (var i = 0; i < forms.length; i++) {
          try {
            var f = forms[i];
            result.push({
              id: safeStr(f.id),
              name: safeStr(f.getAttribute('name')),
              action: safeStr(f.action),
              method: safeStr(f.method)
            });
          } catch (e) {}
        }
      } catch (e) {}
      return result;
    }

    function collectButtons() {
      var result = [];
      try {
        var btns = document.querySelectorAll(
          'button, input[type="submit"], input[type="button"], a.btn, a[role="button"]'
        );
        for (var i = 0; i < btns.length; i++) {
          try {
            var b = btns[i];
            result.push({
              id: safeStr(b.id),
              name: safeStr(b.getAttribute('name')),
              text: safeText(b),
              value: safeStr(b.value),
              className: safeStr(b.className),
              type: safeStr(b.type || b.getAttribute('type'))
            });
          } catch (e) {}
        }
      } catch (e) {}
      return result;
    }

    function collectCourseRows() {
      var result = [];
      try {
        var rows = document.querySelectorAll('tr');
        for (var i = 0; i < rows.length; i++) {
          try {
            var r = rows[i];
            var cells = r.querySelectorAll('td');
            if (cells.length >= 3) {
              var rowData = [];
              for (var j = 0; j < cells.length && j < 10; j++) {
                rowData.push(safeText(cells[j]));
              }
              result.push({ index: i, cells: rowData });
            }
          } catch (e) {}
        }
      } catch (e) {}
      return result;
    }

    function detectLoginForm() {
      try {
        var pwds = document.querySelectorAll('input[type="password"]');
        if (pwds.length > 0) return true;
        var inputs = document.querySelectorAll('input[type="text"]');
        var hasUser = false, hasPwd = false;
        for (var i = 0; i < inputs.length; i++) {
          var ph = (inputs[i].placeholder || '').toLowerCase();
          var nm = (inputs[i].name || '').toLowerCase();
          var id = (inputs[i].id || '').toLowerCase();
          var combined = ph + ' ' + nm + ' ' + id;
          if (combined.indexOf('用户') >= 0 || combined.indexOf('学号') >= 0 ||
              combined.indexOf('username') >= 0 || combined.indexOf('account') >= 0) {
            hasUser = true;
          }
          if (combined.indexOf('密码') >= 0 || combined.indexOf('password') >= 0) {
            hasPwd = true;
          }
        }
        return hasUser && hasPwd;
      } catch (e) { return false; }
    }

    function detectEvaluationForm() {
      try {
        var radios = document.querySelectorAll('input[type="radio"]');
        var groups = {};
        for (var i = 0; i < radios.length; i++) {
          var nm = radios[i].name || '__none__';
          groups[nm] = (groups[nm] || 0) + 1;
        }
        var multiGroups = 0;
        var keys = Object.keys(groups);
        for (var k = 0; k < keys.length; k++) {
          if (groups[keys[k]] >= 2) multiGroups++;
        }
        // Need at least 3 groups with ≥2 options to be an evaluation form
        if (multiGroups >= 3) return true;

        var body = fullBody.substring(0, 2000);
        var evalKeywords = ['评价指标','教学态度','教学内容','教学方法','评教','打分'];
        var hits = 0;
        for (var i = 0; i < evalKeywords.length; i++) {
          if (body.indexOf(evalKeywords[i]) >= 0) hits++;
        }
        return hits >= 2;
      } catch (e) { return false; }
    }

    // ── Main ──
    var bodyText = '';
    try {
      bodyText = fullBody.replace(/\s+/g, ' ').trim().substring(0, MAX_TEXT_SAMPLE);
    } catch (e) {}

    var title = '';
    try { title = document.title || ''; } catch (e) {}

    var textareaCount = 0;
    try { textareaCount = document.querySelectorAll('textarea').length; } catch (e) {}

    var radios = collectRadios();

    return JSON.stringify({
      url: window.location.href || '',
      title: safeStr(title),
      pageTextSample: bodyText,
      radioCount: radios.length,
      radioOptions: radios,
      textareaCount: textareaCount,
      forms: collectForms(),
      buttons: collectButtons(),
      possibleCourseRows: collectCourseRows(),
      hasLoginForm: detectLoginForm(),
      hasEvaluationForm: detectEvaluationForm(),
      hasSubmittedText: hasSubmittedText,
      hasSessionExpiredText: hasSessionExpiredText,
      hasAccessDeniedText: hasAccessDeniedText,
      hasMaintenanceText: hasMaintenanceText,
      hasAlreadyEvaluatedText: hasAlreadyEvaluatedText
    });
  } catch (e) {
    return JSON.stringify({ error: 'Probe script error: ' + (e.message || String(e)) });
  }
})();
''';
}

/// Builds the safe fill JavaScript string.
///
/// Safety constraints:
/// - Only fills groups that have data-dyf/data-score/data-fz attributes
/// - Never uses radio.value as a score
/// - Requires location.pathname contains /xspjgl/
/// - Requires ≥ 3 scorable groups
/// - Single-click strategy (no duplicate events)
/// - Hidden radios with visible labels are still fillable
/// - NEVER clicks submit/save, NEVER makes HTTP requests
String buildFillScript() {
  return r'''
(function () {
  'use strict';
  try {
    function safeStr(s) {
      if (s == null) return '';
      return String(s).substring(0, 120);
    }

    // ═══ Pre-fill safety gate ═══

    // Gate 1: Must be on /xspjgl/ path
    if (window.location.pathname.indexOf('/xspjgl/') < 0) {
      return JSON.stringify({
        totalGroups: 0,
        completedGroups: 0,
        unresolvedGroups: [],
        alreadyCompletedGroups: 0,
        textareaCount: 0,
        requiredTextareas: [],
        warnings: ['当前页面不在评价路径 (/xspjgl/) 内，拒绝填写'],
        error: '页面路径不符合评价系统要求'
      });
    }

    // ── Extract score from data attributes ONLY ──
    // Never uses radio.value as a score.
    function extractScore(opt) {
      var candidates = [
        opt.getAttribute('data-dyf'),
        opt.getAttribute('data-score'),
        opt.getAttribute('data-fz')
      ];
      for (var i = 0; i < candidates.length; i++) {
        var v = parseFloat(candidates[i]);
        if (!isNaN(v) && isFinite(v) && v >= 0) return v;
      }
      return null; // No explicit score → unresolved
    }

    // ── Visibility: check the radio AND its associated label/parent ──
    function isEffectivelyVisible(el) {
      try {
        // Check for explicit hiding via CSS
        var style = window.getComputedStyle(el);
        if (style && (style.display === 'none' || style.visibility === 'hidden')) {
          // Even if input is hidden, its label or parent container may be visible.
          // Look for an associated visible element.
          var label = null;
          if (el.id) {
            label = document.querySelector('label[for="' + el.id + '"]');
          }
          if (!label) label = el.closest('label');
          if (!label) label = el.closest('tr, li, .radio, .option, .item, td, div[class]');
          if (label) {
            var ls = window.getComputedStyle(label);
            if (ls && ls.display !== 'none' && ls.visibility !== 'hidden') return true;
          }
          return false;
        }
        return true;
      } catch (e) { return true; } // conservative
    }

    // ── Group radios by name ──
    var allRadios = document.querySelectorAll('input[type="radio"]');
    var groups = {};
    for (var i = 0; i < allRadios.length; i++) {
      try {
        var r = allRadios[i];
        var key = r.name || r.id || ('__anon_' + i);
        if (!groups[key]) groups[key] = [];
        groups[key].push(r);
      } catch (e) {}
    }

    var keys = Object.keys(groups);

    // Gate 2: Need at least 3 groups with ≥2 options
    var viableGroups = 0;
    for (var g = 0; g < keys.length; g++) {
      if (groups[keys[g]].length >= 2) viableGroups++;
    }
    if (viableGroups < 3) {
      return JSON.stringify({
        totalGroups: keys.length,
        completedGroups: 0,
        unresolvedGroups: [],
        alreadyCompletedGroups: 0,
        textareaCount: 0,
        requiredTextareas: [],
        warnings: ['可评分分组不足 (需要 ≥3 组，当前 ' + viableGroups + ' 组)'],
        error: '页面评价结构不符合填写要求'
      });
    }

    // Gate 3: Need at least 3 groups with explicit score attributes
    var scoreableCount = 0;
    for (var g2 = 0; g2 < keys.length; g2++) {
      var opts = groups[keys[g2]];
      for (var j = 0; j < opts.length; j++) {
        if (extractScore(opts[j]) !== null) { scoreableCount++; break; }
      }
    }
    if (scoreableCount < 3) {
      return JSON.stringify({
        totalGroups: keys.length,
        completedGroups: 0,
        unresolvedGroups: keys.map(function(k){return safeStr(k);}),
        alreadyCompletedGroups: 0,
        textareaCount: 0,
        requiredTextareas: [],
        warnings: ['仅有 ' + scoreableCount + ' 组具有明确分值属性 (data-dyf/data-score/data-fz)'],
        error: '页面选项缺少可识别的分值属性，请手动填写'
      });
    }

    // ═══ Fill phase ═══
    var totalGroups = 0;
    var completedGroups = 0;
    var alreadyCompletedGroups = 0;
    var unresolvedGroups = [];
    var warnings = [];

    for (var g3 = 0; g3 < keys.length; g3++) {
      var key = keys[g3];
      var opts = groups[key];
      totalGroups++;

      // Check already completed
      var alreadyDone = false;
      for (var ai = 0; ai < opts.length; ai++) {
        if (opts[ai].checked && !opts[ai].disabled) {
          alreadyDone = true;
          break;
        }
      }
      if (alreadyDone) {
        alreadyCompletedGroups++;
        continue;
      }

      // Filter to non-disabled, effectively visible options
      var enabledOpts = [];
      for (var ej = 0; ej < opts.length; ej++) {
        if (!opts[ej].disabled && isEffectivelyVisible(opts[ej])) {
          enabledOpts.push(opts[ej]);
        }
      }

      if (enabledOpts.length === 0) {
        unresolvedGroups.push(safeStr(key));
        warnings.push('Group "' + safeStr(key) + '" has no enabled visible options');
        continue;
      }

      // Find best score using EXPLICIT attributes only
      var best = null;
      var bestScore = null;
      for (var bk = 0; bk < enabledOpts.length; bk++) {
        var score = extractScore(enabledOpts[bk]);
        if (score !== null && (bestScore === null || score > bestScore)) {
          bestScore = score;
          best = enabledOpts[bk];
        }
      }

      if (best !== null) {
        // ── Single-path click strategy ──
        var clicked = false;
        try { best.click(); clicked = true; } catch (e) { /* click threw */ }

        // Verify click worked
        if (!best.checked && clicked) {
          // Native click didn't take — try setting checked directly
          try { best.checked = true; } catch (e) {}
        }

        if (best.checked) {
          // Click succeeded — fire one input + one change (no jQuery click)
          try { best.dispatchEvent(new Event('input', { bubbles: true })); } catch (e) {}
          try { best.dispatchEvent(new Event('change', { bubbles: true })); } catch (e) {}
          // jQuery compat: only trigger change (not click) for frameworks
          if (typeof jQuery !== 'undefined' && jQuery.fn) {
            try { jQuery(best).trigger('change'); } catch (e) {}
          }
        } else {
          // Click and manual set both failed — try jQuery as last resort
          if (typeof jQuery !== 'undefined' && jQuery.fn) {
            try {
              jQuery(best).prop('checked', true).trigger('change');
              if (best.checked) clicked = true;
            } catch (e) {}
          }
          // Still not checked — mark unresolved
          if (!best.checked) {
            unresolvedGroups.push(safeStr(key));
            warnings.push('Group "' + safeStr(key) + '": unable to select best option');
            continue;
          }
        }

        completedGroups++;
      } else {
        unresolvedGroups.push(safeStr(key));
        warnings.push('Group "' + safeStr(key) + '" has no scoreable options');
      }
    }

    // ── Textarea detection (no auto-fill) ──
    var textareas = document.querySelectorAll('textarea');
    var textInputs = document.querySelectorAll('input[type="text"]');
    var requiredTextareas = [];
    for (var t = 0; t < textareas.length; t++) {
      if (textareas[t].required || textareas[t].getAttribute('required') !== null) {
        requiredTextareas.push(
          safeStr(textareas[t].name || textareas[t].id || ('textarea_' + t))
        );
      }
    }
    for (var ti = 0; ti < textInputs.length; ti++) {
      if (textInputs[ti].required || textInputs[ti].getAttribute('required') !== null) {
        requiredTextareas.push(
          safeStr(textInputs[ti].name || textInputs[ti].id || ('textinput_' + ti))
        );
      }
    }

    // ── Post-fill validation ──
    var postCheckedCount = 0;
    for (var vg = 0; vg < keys.length; vg++) {
      var vopts = groups[keys[vg]];
      for (var vm = 0; vm < vopts.length; vm++) {
        if (vopts[vm].checked && !vopts[vm].disabled) { postCheckedCount++; break; }
      }
    }
    if (postCheckedCount < completedGroups + alreadyCompletedGroups) {
      warnings.push(
        'Post-fill check: only ' + postCheckedCount + '/' +
        (completedGroups + alreadyCompletedGroups) + ' groups show as checked'
      );
    }

    return JSON.stringify({
      totalGroups: totalGroups,
      completedGroups: completedGroups,
      unresolvedGroups: unresolvedGroups,
      alreadyCompletedGroups: alreadyCompletedGroups,
      textareaCount: textareas.length + textInputs.length,
      requiredTextareas: requiredTextareas,
      warnings: warnings
    });
  } catch (e) {
    return JSON.stringify({ error: 'Fill script error: ' + (e.message || String(e)) });
  }
})();
''';
}

/// Builds a lightweight validation-only script (re-check after fill).
String buildValidateScript() {
  return r'''
(function () {
  'use strict';
  try {
    var allRadios = document.querySelectorAll('input[type="radio"]');
    var groups = {};
    for (var i = 0; i < allRadios.length; i++) {
      try {
        var r = allRadios[i];
        var key = r.name || r.id || ('__anon_' + i);
        if (!groups[key]) groups[key] = { total: 0, checked: 0 };
        groups[key].total++;
      } catch (e) {}
    }
    for (var j = 0; j < allRadios.length; j++) {
      try {
        var r2 = allRadios[j];
        var k = r2.name || r2.id || ('__anon_' + j);
        if (r2.checked && !r2.disabled && groups[k]) groups[k].checked++;
      } catch (e) {}
    }
    var unselected = [];
    var keys = Object.keys(groups);
    for (var g = 0; g < keys.length; g++) {
      if (groups[keys[g]].checked === 0) unselected.push(keys[g]);
    }
    return JSON.stringify({
      totalGroups: keys.length,
      selectedGroups: keys.length - unselected.length,
      unselectedGroups: unselected
    });
  } catch (e) {
    return JSON.stringify({ error: 'Validate script error: ' + (e.message || String(e)) });
  }
})();
''';
}
