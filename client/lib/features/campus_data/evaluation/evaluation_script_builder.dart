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

    function traverseFrames(win, callback) {
      try {
        callback(win.document, win.location.pathname);
      } catch(e) {}
      try {
        for (var i = 0; i < win.frames.length; i++) {
          traverseFrames(win.frames[i], callback);
        }
      } catch(e) {}
    }

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
    
    var hasAccessDeniedText = false;
    try {
      var title = (document.title || '').toLowerCase();
      if (title.indexOf('无权限') >= 0 || title.indexOf('禁止访问') >= 0 || title.indexOf('access denied') >= 0 || title.indexOf('forbidden') >= 0) {
        hasAccessDeniedText = true;
      }
      if (!hasAccessDeniedText) {
        var errs = document.querySelectorAll('.error-page, .error-message, #error, .alert-danger');
        for (var i = 0; i < errs.length; i++) {
          var t = (errs[i].textContent || '').toLowerCase();
          if (t.indexOf('无权限') >= 0 || t.indexOf('禁止访问') >= 0 || t.indexOf('access denied') >= 0) {
            hasAccessDeniedText = true; break;
          }
        }
      }
    } catch(e){}

    var hasMaintenanceText = bodyContainsAny([
      '系统维护','正在维护','暂未开放','系统升级'
    ]);
    var hasAlreadyEvaluatedText = bodyContainsAny([
      '已评价','已完成','已提交','查看评价'
    ]);

    var allRadios = [];
    var allScoreInputs = [];
    var textareaCount = 0;
    var optionalCommentCount = 0;
    var allForms = [];
    var allButtons = [];
    var possibleCourseRows = [];

    function isVisible(el) {
      try {
        var style = window.getComputedStyle(el);
        if (style && (style.display === 'none' || style.visibility === 'hidden')) return false;
        if (el.offsetWidth === 0 && el.offsetHeight === 0) return false;
        return true;
      } catch(e) { return true; }
    }

    var rangeRegex = /(?:打分|评分)?范围\s*[:：]?\s*(-?\d+(?:\.\d+)?)\s*(?:-|~|～|至)\s*(-?\d+(?:\.\d+)?)/gi;

    function extractRange(el) {
      if (el.hasAttribute('min') && el.hasAttribute('max')) {
        return { min: parseFloat(el.getAttribute('min')), max: parseFloat(el.getAttribute('max')), source: 'minMax', ambiguous: false };
      }
      if (el.hasAttribute('data-min') && el.hasAttribute('data-max')) {
        return { min: parseFloat(el.getAttribute('data-min')), max: parseFloat(el.getAttribute('data-max')), source: 'dataAttr', ambiguous: false };
      }
      var ph = el.getAttribute('placeholder') || '';
      rangeRegex.lastIndex = 0;
      var m = rangeRegex.exec(ph);
      if (m !== null) {
        return { min: parseFloat(m[1]), max: parseFloat(m[2]), source: 'placeholder', ambiguous: false };
      }
      var container = el.closest('td, li, div.form-group, .question, tr');
      if (container) {
        var text = container.textContent || '';
        rangeRegex.lastIndex = 0;
        var match1 = rangeRegex.exec(text);
        if (match1) {
          var match2 = rangeRegex.exec(text);
          if (match2 && (match1[1] !== match2[1] || match1[2] !== match2[2])) {
            return { min: parseFloat(match1[1]), max: parseFloat(match1[2]), source: 'text', ambiguous: true };
          }
          return { min: parseFloat(match1[1]), max: parseFloat(match1[2]), source: 'text', ambiguous: false };
        }
      }
      return null;
    }

    function isOptionalCommentField(el) {
      if (el.tagName && el.tagName.toLowerCase() === 'textarea') return true;
      if (el.isContentEditable) return true;
      var container = el.closest('td, li, div.form-group, tr');
      if (container) {
        var text = container.textContent || '';
        if (text.indexOf('建议') >= 0 || text.indexOf('意见') >= 0 || text.indexOf('评语') >= 0) {
          return true;
        }
      }
      return false;
    }

    traverseFrames(window, function(doc, framePath) {
      var radios = doc.querySelectorAll('input[type="radio"]');
      for (var i = 0; i < radios.length; i++) {
        var r = radios[i];
        allRadios.push({
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
      }

      var textareas = doc.querySelectorAll('textarea');
      textareaCount += textareas.length;
      for (var i = 0; i < textareas.length; i++) {
        if (isOptionalCommentField(textareas[i])) optionalCommentCount++;
      }

      var inputs = doc.querySelectorAll('input:not([type="radio"]):not([type="checkbox"]):not([type="submit"]):not([type="button"]):not([type="hidden"])');
      for (var i = 0; i < inputs.length; i++) {
        var inp = inputs[i];
        var type = (inp.getAttribute('type') || '').toLowerCase();
        if (type !== 'text' && type !== 'number' && type !== '') continue;
        
        var nameId = (inp.name || inp.id || '').toLowerCase();
        if (nameId.indexOf('search') >= 0) continue;

        if (isOptionalCommentField(inp)) {
          optionalCommentCount++;
          continue;
        }

        var rng = extractRange(inp);
        var visible = isVisible(inp);

        if (!rng && !inp.disabled && !inp.readOnly && visible) {
          continue; 
        }

        allScoreInputs.push({
          id: safeStr(inp.id),
          name: safeStr(inp.name),
          className: safeStr(inp.className),
          type: safeStr(inp.getAttribute('type')),
          placeholder: safeStr(inp.getAttribute('placeholder')),
          disabled: !!inp.disabled,
          readOnly: !!inp.readOnly,
          isVisible: visible,
          framePath: safeStr(framePath),
          minScore: rng ? rng.min : null,
          maxScore: rng ? rng.max : null,
          rangeSource: rng ? rng.source : null,
          rangeIsAmbiguous: rng ? rng.ambiguous : false,
          isOptionalComment: false
        });
      }

      var forms = doc.querySelectorAll('form');
      for (var i = 0; i < forms.length; i++) {
        var f = forms[i];
        allForms.push({
          id: safeStr(f.id),
          name: safeStr(f.getAttribute('name')),
          action: safeStr(f.action),
          method: safeStr(f.method)
        });
      }

      var btns = doc.querySelectorAll('button, input[type="submit"], input[type="button"], a.btn, a[role="button"]');
      for (var i = 0; i < btns.length; i++) {
        var b = btns[i];
        allButtons.push({
          id: safeStr(b.id),
          name: safeStr(b.getAttribute('name')),
          text: safeText(b),
          value: safeStr(b.value),
          className: safeStr(b.className),
          type: safeStr(b.type || b.getAttribute('type'))
        });
      }

      var rows = doc.querySelectorAll('tr');
      for (var i = 0; i < rows.length; i++) {
        var r = rows[i];
        var cells = r.querySelectorAll('td');
        if (cells.length >= 3) {
          var rowData = [];
          for (var j = 0; j < cells.length && j < 10; j++) {
            rowData.push(safeText(cells[j]));
          }
          possibleCourseRows.push({ index: i, cells: rowData });
        }
      }
    });

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
        var groups = {};
        for (var i = 0; i < allRadios.length; i++) {
          var nm = allRadios[i].name || '__none__';
          groups[nm] = (groups[nm] || 0) + 1;
        }
        var multiGroups = 0;
        var keys = Object.keys(groups);
        for (var k = 0; k < keys.length; k++) {
          if (groups[keys[k]] >= 2) multiGroups++;
        }
        if (multiGroups >= 3) return true;

        var reliableScoreInputs = 0;
        for (var i = 0; i < allScoreInputs.length; i++) {
          var s = allScoreInputs[i];
          if (!s.disabled && !s.readOnly && s.isVisible && !s.rangeIsAmbiguous && s.maxScore !== null && s.maxScore > (s.minScore||0)) {
            reliableScoreInputs++;
          }
        }
        if (reliableScoreInputs >= 3) return true;

        var body = fullBody.substring(0, 2000);
        var evalKeywords = ['评价指标','教学态度','教学内容','教学方法','评教','打分'];
        var hits = 0;
        for (var i = 0; i < evalKeywords.length; i++) {
          if (body.indexOf(evalKeywords[i]) >= 0) hits++;
        }
        return hits >= 2;
      } catch (e) { return false; }
    }

    var bodyText = '';
    try {
      bodyText = fullBody.replace(/\s+/g, ' ').trim().substring(0, MAX_TEXT_SAMPLE);
    } catch (e) {}

    var title = '';
    try { title = document.title || ''; } catch (e) {}

    return JSON.stringify({
      url: window.location.href || '',
      title: safeStr(title),
      pageTextSample: bodyText,
      radioCount: allRadios.length,
      radioOptions: allRadios,
      scoreInputs: allScoreInputs,
      textareaCount: textareaCount,
      optionalCommentCount: optionalCommentCount,
      forms: allForms,
      buttons: allButtons,
      possibleCourseRows: possibleCourseRows,
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
String buildFillScript() {
  return r'''
(function () {
  'use strict';
  try {
    function safeStr(s) {
      if (s == null) return '';
      return String(s).substring(0, 120);
    }

    if (window.location.pathname.indexOf('/xspjgl/') < 0) {
      return JSON.stringify({
        radioTotalGroups: 0,
        radioCompletedGroups: 0,
        scoreInputCount: 0,
        scoreInputCompletedCount: 0,
        unresolvedRadioGroups: [],
        unresolvedScoreInputs: [],
        optionalCommentCount: 0,
        warnings: ['当前页面不在评价路径 (/xspjgl/) 内，拒绝填写'],
        error: '页面路径不符合评价系统要求'
      });
    }

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
      return null;
    }

    function isEffectivelyVisible(el) {
      try {
        var style = window.getComputedStyle(el);
        if (style && (style.display === 'none' || style.visibility === 'hidden')) {
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
        if (el.offsetWidth === 0 && el.offsetHeight === 0) return false;
        return true;
      } catch (e) { return true; }
    }

    var rangeRegex = /(?:打分|评分)?范围\s*[:：]?\s*(-?\d+(?:\.\d+)?)\s*(?:-|~|～|至)\s*(-?\d+(?:\.\d+)?)/gi;

    function extractRange(el) {
      if (el.hasAttribute('min') && el.hasAttribute('max')) {
        return { min: parseFloat(el.getAttribute('min')), max: parseFloat(el.getAttribute('max')), source: 'minMax', ambiguous: false };
      }
      if (el.hasAttribute('data-min') && el.hasAttribute('data-max')) {
        return { min: parseFloat(el.getAttribute('data-min')), max: parseFloat(el.getAttribute('data-max')), source: 'dataAttr', ambiguous: false };
      }
      var ph = el.getAttribute('placeholder') || '';
      rangeRegex.lastIndex = 0;
      var m = rangeRegex.exec(ph);
      if (m !== null) {
        return { min: parseFloat(m[1]), max: parseFloat(m[2]), source: 'placeholder', ambiguous: false };
      }
      var container = el.closest('td, li, div.form-group, .question, tr');
      if (container) {
        var text = container.textContent || '';
        rangeRegex.lastIndex = 0;
        var match1 = rangeRegex.exec(text);
        if (match1) {
          var match2 = rangeRegex.exec(text);
          if (match2 && (match1[1] !== match2[1] || match1[2] !== match2[2])) {
            return { min: parseFloat(match1[1]), max: parseFloat(match1[2]), source: 'text', ambiguous: true };
          }
          return { min: parseFloat(match1[1]), max: parseFloat(match1[2]), source: 'text', ambiguous: false };
        }
      }
      return null;
    }

    var allRadios = [];
    var allScoreInputs = [];
    
    function traverseFrames(win) {
      try {
        var doc = win.document;
        var radios = doc.querySelectorAll('input[type="radio"]');
        for (var i = 0; i < radios.length; i++) allRadios.push(radios[i]);

        var inputs = doc.querySelectorAll('input:not([type="radio"]):not([type="checkbox"]):not([type="submit"]):not([type="button"]):not([type="hidden"])');
        for (var i = 0; i < inputs.length; i++) {
          var inp = inputs[i];
          var type = (inp.getAttribute('type') || '').toLowerCase();
          if (type !== 'text' && type !== 'number' && type !== '') continue;
          var nameId = (inp.name || inp.id || '').toLowerCase();
          if (nameId.indexOf('search') >= 0) continue;
          allScoreInputs.push(inp);
        }
      } catch(e) {}
      try {
        for (var i = 0; i < win.frames.length; i++) {
          traverseFrames(win.frames[i]);
        }
      } catch(e) {}
    }

    traverseFrames(window);

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

    var scoreableGroups = 0;
    for (var g = 0; g < keys.length; g++) {
      var opts = groups[keys[g]];
      if (opts.length >= 2) {
        for (var j = 0; j < opts.length; j++) {
          if (extractScore(opts[j]) !== null) { scoreableGroups++; break; }
        }
      }
    }

    var validScoreInputs = [];
    for (var i = 0; i < allScoreInputs.length; i++) {
      var inp = allScoreInputs[i];
      if (inp.disabled || inp.readOnly || !isEffectivelyVisible(inp)) continue;
      
      var isComment = false;
      var container = inp.closest('td, li, div.form-group, tr');
      if (container) {
        var text = container.textContent || '';
        if (text.indexOf('建议') >= 0 || text.indexOf('意见') >= 0 || text.indexOf('评语') >= 0) {
          isComment = true;
        }
      }
      if (isComment) continue;

      var rng = extractRange(inp);
      if (rng && !rng.ambiguous && rng.max > rng.min) {
        validScoreInputs.push({ element: inp, max: rng.max });
      }
    }

    if (scoreableGroups < 3 && validScoreInputs.length < 3) {
      return JSON.stringify({
        radioTotalGroups: keys.length,
        radioCompletedGroups: 0,
        scoreInputCount: validScoreInputs.length,
        scoreInputCompletedCount: 0,
        unresolvedRadioGroups: [],
        unresolvedScoreInputs: [],
        optionalCommentCount: 0,
        warnings: ['未检测到足够数量的可评分控件 (需要 ≥3 组单选 或 ≥3 个评分输入框)'],
        error: '页面评价结构不符合填写要求'
      });
    }

    var radioTotalGroups = 0;
    var radioCompletedGroups = 0;
    var unresolvedRadioGroups = [];
    var unresolvedScoreInputs = [];
    var warnings = [];

    for (var g3 = 0; g3 < keys.length; g3++) {
      var key = keys[g3];
      var opts = groups[key];
      radioTotalGroups++;

      var alreadyDone = false;
      for (var ai = 0; ai < opts.length; ai++) {
        if (opts[ai].checked && !opts[ai].disabled) {
          alreadyDone = true; break;
        }
      }
      if (alreadyDone) {
        radioCompletedGroups++;
        continue;
      }

      var enabledOpts = [];
      for (var ej = 0; ej < opts.length; ej++) {
        if (!opts[ej].disabled && isEffectivelyVisible(opts[ej])) {
          enabledOpts.push(opts[ej]);
        }
      }

      if (enabledOpts.length === 0) {
        unresolvedRadioGroups.push(safeStr(key));
        warnings.push('Group "' + safeStr(key) + '" has no enabled visible options');
        continue;
      }

      var best = null;
      var bestScore = null;
      for (var bk = 0; bk < enabledOpts.length; bk++) {
        var score = extractScore(enabledOpts[bk]);
        if (score !== null && (bestScore === null || score > bestScore)) {
          bestScore = score; best = enabledOpts[bk];
        }
      }

      if (best !== null) {
        var clicked = false;
        try { best.click(); clicked = true; } catch (e) {}
        if (!best.checked && clicked) {
          try { best.checked = true; } catch (e) {}
        }
        if (best.checked) {
          try { best.dispatchEvent(new Event('input', { bubbles: true })); } catch (e) {}
          try { best.dispatchEvent(new Event('change', { bubbles: true })); } catch (e) {}
          if (typeof jQuery !== 'undefined' && jQuery.fn) {
            try { jQuery(best).trigger('change'); } catch (e) {}
          }
        } else {
          if (typeof jQuery !== 'undefined' && jQuery.fn) {
            try {
              jQuery(best).prop('checked', true).trigger('change');
              if (best.checked) clicked = true;
            } catch (e) {}
          }
          if (!best.checked) {
            unresolvedRadioGroups.push(safeStr(key));
            warnings.push('Group "' + safeStr(key) + '": unable to select best option');
            continue;
          }
        }
        radioCompletedGroups++;
      } else {
        if (extractScore(opts[0]) !== null) {
          unresolvedRadioGroups.push(safeStr(key));
          warnings.push('Group "' + safeStr(key) + '" has no scoreable options');
        } else {
          // If the group never had a score attribute, don't complain unless we fall back to it
          radioTotalGroups--; 
        }
      }
    }

    var scoreInputCompletedCount = 0;
    for (var i = 0; i < validScoreInputs.length; i++) {
      var item = validScoreInputs[i];
      var inp = item.element;
      var max = item.max;
      var valStr = String(max);

      var setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value');
      if (setter && setter.set) {
        try { setter.set.call(inp, valStr); } catch (e) { inp.value = valStr; }
      } else {
        inp.value = valStr;
      }
      
      try { inp.dispatchEvent(new Event('input', { bubbles: true })); } catch(e){}
      try { inp.dispatchEvent(new Event('change', { bubbles: true })); } catch(e){}
      try { inp.dispatchEvent(new Event('blur', { bubbles: true })); } catch(e){}

      if (inp.value !== valStr && typeof jQuery !== 'undefined' && jQuery.fn) {
        try {
          jQuery(inp).val(valStr).trigger('input').trigger('change').trigger('blur');
        } catch(e){}
      }

      if (inp.value === valStr) {
        scoreInputCompletedCount++;
      } else {
        unresolvedScoreInputs.push("评分项 #" + (i + 1));
        warnings.push("无法填写评分项 #" + (i + 1));
      }
    }

    var optCount = 0;
    try {
      var textareas = document.querySelectorAll('textarea');
      optCount += textareas.length;
    } catch(e) {}

    return JSON.stringify({
      radioTotalGroups: radioTotalGroups,
      radioCompletedGroups: radioCompletedGroups,
      scoreInputCount: validScoreInputs.length,
      scoreInputCompletedCount: scoreInputCompletedCount,
      unresolvedRadioGroups: unresolvedRadioGroups,
      unresolvedScoreInputs: unresolvedScoreInputs,
      optionalCommentCount: optCount,
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
    return JSON.stringify({});
  } catch (e) {
    return JSON.stringify({ error: 'Validate script error: ' + (e.message || String(e)) });
  }
})();
''';
}

