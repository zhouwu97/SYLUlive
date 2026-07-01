library;

/// Helper JS string to identify if a button is a submit action.
const String _isSubmitActionJs = r'''
    function isSubmitAction(element) {
      if (!element) return false;
      var text = (element.innerText || element.value || element.getAttribute('title') || '').replace(/\s+/g, '').toLowerCase();
      if (text.indexOf('提交') >= 0) return true;
      if (text.indexOf('submit') >= 0) return true;
      return false;
    }
''';

/// JavaScript to find and click the exact "保存" button.
String buildSaveCurrentScript() {
  return '''
(function () {
  'use strict';
  try {
    $_isSubmitActionJs

    function findSaveButton() {
      var btns = document.querySelectorAll('button, input[type="submit"], input[type="button"], a.btn, a[role="button"]');
      var candidates = [];
      for (var i = 0; i < btns.length; i++) {
        var b = btns[i];
        if (b.disabled) continue;
        
        var style = window.getComputedStyle(b);
        if (style && (style.display === 'none' || style.visibility === 'hidden')) continue;
        if (b.offsetWidth === 0 && b.offsetHeight === 0) continue;

        if (isSubmitAction(b)) continue;

        var text = (b.innerText || b.value || b.getAttribute('title') || '').replace(/\\s+/g, '');
        if (text === '保存') {
          candidates.push(b);
        }
      }
      return candidates;
    }

    var candidates = findSaveButton();
    if (candidates.length === 0) {
      return JSON.stringify({ error: '未找到明确的保存按钮' });
    }
    if (candidates.length > 1) {
      return JSON.stringify({ error: '找到多个保存按钮，为安全起见放弃点击' });
    }

    var saveBtn = candidates[0];
    try {
      saveBtn.scrollIntoView({ behavior: 'smooth', block: 'center' });
    } catch(e) {}

    // Perform click
    saveBtn.click();

    return JSON.stringify({ success: true, message: '已点击保存按钮' });
  } catch (e) {
    return JSON.stringify({ error: 'Save script exception: ' + (e.message || String(e)) });
  }
})();
''';
}

/// JavaScript to find and click the exact "提交" button.
String buildSubmitCurrentScript() {
  return '''
(function () {
  'use strict';
  try {
    $_isSubmitActionJs

    function findSubmitButton() {
      var btns = document.querySelectorAll('button, input[type="submit"], input[type="button"], a.btn, a[role="button"]');
      var candidates = [];
      for (var i = 0; i < btns.length; i++) {
        var b = btns[i];
        if (b.disabled) continue;
        
        var style = window.getComputedStyle(b);
        if (style && (style.display === 'none' || style.visibility === 'hidden')) continue;
        if (b.offsetWidth === 0 && b.offsetHeight === 0) continue;

        if (isSubmitAction(b)) {
          candidates.push(b);
        }
      }
      return candidates;
    }

    var candidates = findSubmitButton();
    if (candidates.length === 0) {
      return JSON.stringify({ error: '未找到明确的提交按钮' });
    }

    var submitBtn = candidates[0];
    try {
      submitBtn.scrollIntoView({ behavior: 'smooth', block: 'center' });
    } catch(e) {}

    // Perform click
    submitBtn.click();

    // Auto confirm any immediate bootbox/layer confirm modals
    setTimeout(function() {
      var confirmBtns = document.querySelectorAll('.bootbox-accept, .layui-layer-btn0, button.confirm, button.ok');
      for (var j = 0; j < confirmBtns.length; j++) {
        var cb = confirmBtns[j];
        var text = (cb.textContent || '').replace(/\\s+/g, '');
        if (text.indexOf('确定') >= 0 || text.indexOf('确认') >= 0 || text.indexOf('提交') >= 0) {
           try { cb.click(); } catch(e) {}
        }
      }
    }, 500);

    return JSON.stringify({ success: true, message: '已点击提交按钮' });
  } catch (e) {
    return JSON.stringify({ error: 'Submit script exception: ' + (e.message || String(e)) });
  }
})();
''';
}

/// Snapshot the current state to check if save was successful
String buildSaveSnapshotScript() {
  return '''
(function () {
  'use strict';
  try {
    var fingerprint = '';
    var courseRows = [];
    var rowStatus = null;
    var savedCount = 0;
    var successMarkerCount = 0;

    var activeRow = document.querySelector('tr.ui-state-highlight');
    if (activeRow) {
      var rowId = activeRow.getAttribute('id') || '';
      var cells = activeRow.querySelectorAll('td');
      var headerCells = document.querySelectorAll('.ui-jqgrid-htable th');
      var statusColIndex = -1, courseColIndex = -1, teacherColIndex = -1;
      
      for (var i = 0; i < headerCells.length; i++) {
        var ht = (headerCells[i].textContent || '').replace(/\\s+/g, '');
        if (ht.indexOf('状态') >= 0) statusColIndex = i;
        if (ht.indexOf('课程') >= 0) courseColIndex = i;
        if (ht.indexOf('教师') >= 0) teacherColIndex = i;
      }
      if (statusColIndex === -1) statusColIndex = 6;

      fingerprint = rowId;
      if (courseColIndex >= 0 && courseColIndex < cells.length) {
        fingerprint += '|' + (cells[courseColIndex].textContent || '').trim();
      }
      if (teacherColIndex >= 0 && teacherColIndex < cells.length) {
        fingerprint += '|' + (cells[teacherColIndex].textContent || '').trim();
      }

      if (statusColIndex >= 0 && statusColIndex < cells.length) {
        var ct = cells[statusColIndex].textContent || '';
        if (ct.indexOf('保存') >= 0 || ct.indexOf('评价状态') >= 0 || ct.indexOf('已评') >= 0 || ct.indexOf('未评') >= 0) {
          rowStatus = ct.trim();
        } else {
          rowStatus = ct.trim();
        }
      }
    }

    // Attempt to grab overall saved count if visible at the top
    var savedTextEl = document.querySelector('.saved-count, #savedCount');
    if (savedTextEl) {
      var match = (savedTextEl.textContent || '').match(/(\\d+)/);
      if (match) savedCount = parseInt(match[1], 10);
    }

    // Look for success markers (toids, alert success, etc)
    var successEls = document.querySelectorAll('.alert-success, .success, #successMsg');
    for (var i = 0; i < successEls.length; i++) {
      var t = (successEls[i].textContent || '').replace(/\\s+/g, '');
      if (t.indexOf('保存成功') >= 0 || t.indexOf('提交成功') >= 0 || t.indexOf('评价成功') >= 0 || t.indexOf('操作成功') >= 0) {
        successMarkerCount++;
      }
    }

    // Generic search for "保存/提交成功" in visible elements
    var genericFound = false;
    var allTextEls = document.querySelectorAll('div, span, p, h1, h2, h3, h4');
    for (var i = 0; i < allTextEls.length; i++) {
      var el = allTextEls[i];
      // Only check leaf nodes or text-heavy nodes to avoid matching the whole body
      if (el.children.length === 0 || el.tagName === 'P' || el.tagName === 'SPAN') {
        var text = (el.textContent || '').replace(/\\s+/g, '');
        if (text.indexOf('保存成功') >= 0 || text.indexOf('提交成功') >= 0 || text.indexOf('评价成功') >= 0 || text.indexOf('操作成功') >= 0) {
          var style = window.getComputedStyle(el);
          if (style && style.display !== 'none' && style.visibility !== 'hidden' && el.offsetWidth > 0) {
            genericFound = true;
            break;
          }
        }
      }
    }

    if (genericFound) {
      successMarkerCount++;
      // Attempt to auto-dismiss the modal by clicking "确定"
      var btns = document.querySelectorAll('button, a.btn');
      for (var i = 0; i < btns.length; i++) {
        var bt = (btns[i].textContent || '').replace(/\\s+/g, '');
        if (bt === '确定' || bt === '确认' || bt === 'ok' || bt === '关闭') {
          var bs = window.getComputedStyle(btns[i]);
          if (bs && bs.display !== 'none' && bs.visibility !== 'hidden' && btns[i].offsetWidth > 0) {
            try { btns[i].click(); } catch(e){}
          }
        }
      }
    }

    return JSON.stringify({
      fingerprint: fingerprint.trim().substring(0, 100),
      savedCount: savedCount,
      rowStatus: rowStatus,
      successMarkerCount: successMarkerCount
    });
  } catch (e) {
    return JSON.stringify({ error: String(e) });
  }
})();
''';
}
