library;

/// Selects a specific row by its rowId using jqGrid API if possible.
String buildSelectNextPendingScript(String rowId) {
  return '''
(function () {
  'use strict';
  try {
    var rowId = "$rowId";
    var table = document.querySelector('table.ui-jqgrid-btable');
    if (!table) return JSON.stringify({ error: 'table not found' });

    // Try jqGrid official method first
    if (typeof jQuery !== 'undefined' && jQuery.fn && jQuery.fn.jqGrid) {
      try {
        jQuery(table).jqGrid('setSelection', rowId, true);
        return JSON.stringify({ success: true, method: 'jqGrid' });
      } catch (e) {}
    }

    // Fallback click
    var row = document.getElementById(rowId);
    if (row) {
      row.click();
      return JSON.stringify({ success: true, method: 'click' });
    }

    return JSON.stringify({ error: 'row not found' });
  } catch (e) {
    return JSON.stringify({ error: String(e) });
  }
})();
''';
}

/// Script to trigger "Next Page" in the jqGrid pager.
String buildGoToNextPageScript() {
  return '''
(function () {
  'use strict';
  try {
    var nextBtns = document.querySelectorAll('.ui-pg-button[id^="next_"]');
    var target = null;
    for (var i = 0; i < nextBtns.length; i++) {
      if (!nextBtns[i].classList.contains('ui-state-disabled')) {
        target = nextBtns[i];
        break;
      }
    }

    if (!target) {
      return JSON.stringify({ error: '已到达最后一页或找不到下一页按钮' });
    }

    target.click();
    return JSON.stringify({ success: true });
  } catch (e) {
    return JSON.stringify({ error: String(e) });
  }
})();
''';
}
