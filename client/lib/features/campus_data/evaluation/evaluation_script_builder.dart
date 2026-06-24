/// Centralized JavaScript scripts for the evaluation WebView.
///
/// All scripts are pure functions invoked via `evaluateJavascript`.
/// - Probe script: read-only DOM inspection, returns JSON.
/// - Fill script: selects radio options by group, returns JSON result.
/// - Validate script: re-scans checked state after fill.
library;

/// Builds the page-probe JavaScript string.
///
/// This script is READ-ONLY. It never modifies the DOM, never reads password
/// field values, never captures cookies, and truncates text samples.
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
          } catch (e) { /* skip broken radio */ }
        }
      } catch (e) { /* skip all radios */ }
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
          } catch (e) { /* skip broken form */ }
        }
      } catch (e) { /* skip all forms */ }
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
          } catch (e) { /* skip broken button */ }
        }
      } catch (e) { /* skip all buttons */ }
      return result;
    }

    function collectCourseRows() {
      var result = [];
      try {
        // Look for table rows that might represent courses
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
          } catch (e) { /* skip broken row */ }
        }
      } catch (e) { /* skip all rows */ }
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
        // If we have a substantial number of radio groups, likely evaulation
        if (radios.length >= 5) return true;
        // Check for evaluation-specific text
        var body = (document.body ? document.body.textContent || '' : '').substring(0, 2000);
        var evalKeywords = ['评价', '评分', '指标', '教学', '评教', '打分'];
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
      bodyText = (document.body ? document.body.textContent || '' : '')
        .replace(/\s+/g, ' ').trim().substring(0, MAX_TEXT_SAMPLE);
    } catch (e) { /* ignore */ }

    var title = '';
    try { title = document.title || ''; } catch (e) { /* ignore */ }

    var textareaCount = 0;
    try { textareaCount = document.querySelectorAll('textarea').length; } catch (e) { /* ignore */ }

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
      hasEvaluationForm: detectEvaluationForm()
    });
  } catch (e) {
    return JSON.stringify({ error: 'Probe script error: ' + (e.message || String(e)) });
  }
})();
''';
}

/// Builds the safe fill JavaScript string.
///
/// This script selects the highest-scoring radio option in each group.
/// It NEVER clicks submit/save buttons and NEVER makes HTTP requests.
String buildFillScript() {
  return r'''
(function () {
  'use strict';
  try {
    function safeStr(s) {
      if (s == null) return '';
      return String(s).substring(0, 120);
    }

    function extractScore(opt) {
      // Priority chain: data-dyf → data-score → data-fz → numeric value
      var candidates = [
        opt.getAttribute('data-dyf'),
        opt.getAttribute('data-score'),
        opt.getAttribute('data-fz')
      ];
      for (var i = 0; i < candidates.length; i++) {
        var v = parseFloat(candidates[i]);
        if (!isNaN(v) && isFinite(v)) return v;
      }
      // Fallback: numeric value
      var val = parseFloat(opt.value);
      if (!isNaN(val) && isFinite(val) && val >= 0 && val <= 100) return val;
      return null;
    }

    function triggerEvents(el) {
      try {
        el.dispatchEvent(new Event('input', { bubbles: true }));
        el.dispatchEvent(new Event('change', { bubbles: true }));
        // Compat with jQuery if present
        if (typeof jQuery !== 'undefined' && jQuery.fn) {
          try { jQuery(el).trigger('change'); } catch (e) { /* jQ trigger fail */ }
          try { jQuery(el).trigger('click'); } catch (e) { /* jQ trigger fail */ }
        }
      } catch (e) { /* event trigger failure */ }
    }

    function isVisible(el) {
      try {
        var style = window.getComputedStyle(el);
        if (!style || style.display === 'none' || style.visibility === 'hidden') return false;
        if (el.offsetWidth === 0 && el.offsetHeight === 0) return false;
        return true;
      } catch (e) { return true; } // conservative: assume visible
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
      } catch (e) { /* skip broken radio */ }
    }

    var totalGroups = 0;
    var completedGroups = 0;
    var alreadyCompletedGroups = 0;
    var unresolvedGroups = [];
    var warnings = [];

    var keys = Object.keys(groups);
    for (var g = 0; g < keys.length; g++) {
      var key = keys[g];
      var opts = groups[key];
      totalGroups++;

      // Check if already completed
      var alreadyDone = false;
      for (var i = 0; i < opts.length; i++) {
        if (opts[i].checked && !opts[i].disabled) {
          alreadyDone = true;
          break;
        }
      }
      if (alreadyDone) {
        alreadyCompletedGroups++;
        continue;
      }

      // Filter to visible, non-disabled options
      var enabledOpts = [];
      for (var j = 0; j < opts.length; j++) {
        if (!opts[j].disabled && isVisible(opts[j])) {
          enabledOpts.push(opts[j]);
        }
      }

      if (enabledOpts.length === 0) {
        unresolvedGroups.push(safeStr(key));
        warnings.push('Group "' + safeStr(key) + '" has no enabled visible options');
        continue;
      }

      // Find best score
      var best = null;
      var bestScore = null;
      for (var k = 0; k < enabledOpts.length; k++) {
        var score = extractScore(enabledOpts[k]);
        if (score !== null && (bestScore === null || score > bestScore)) {
          bestScore = score;
          best = enabledOpts[k];
        }
      }

      if (best !== null) {
        // Select the best option
        try { best.click(); } catch (e) { best.checked = true; }
        triggerEvents(best);
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

    // ── Post-fill validation: re-scan checked state ──
    var postCheckedCount = 0;
    for (var g2 = 0; g2 < keys.length; g2++) {
      var opts2 = groups[keys[g2]];
      for (var m = 0; m < opts2.length; m++) {
        if (opts2[m].checked && !opts2[m].disabled) { postCheckedCount++; break; }
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
        if (!groups[key]) groups[key] = { total: 0, checked: 0, names: [] };
        groups[key].total++;
        groups[key].names.push(r.name || r.id || '');
      } catch (e) { /* skip */ }
    }
    // Re-check checked state
    for (var j = 0; j < allRadios.length; j++) {
      try {
        var r2 = allRadios[j];
        var k = r2.name || r2.id || ('__anon_' + j);
        if (r2.checked && !r2.disabled && groups[k]) groups[k].checked++;
      } catch (e) { /* skip */ }
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
