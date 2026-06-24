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
      if (t.indexOf('保存成功') >= 0 || t.indexOf('操作成功') >= 0) {
        successMarkerCount++;
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
