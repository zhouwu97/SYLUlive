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

    var row = document.getElementById(rowId);
    if (!row) return JSON.stringify({ error: 'row not found' });
    
    try { row.scrollIntoView({ block: 'center' }); } catch(e){}
    
    // Always dispatch a native click
    row.click();
    
    // Fallback just in case jqGrid selection is strictly required by some weird bindings
    if (typeof jQuery !== 'undefined' && jQuery.fn && jQuery.fn.jqGrid) {
      try {
        var table = document.querySelector('table.ui-jqgrid-btable');
        if (table) jQuery(table).jqGrid('setSelection', rowId, true);
      } catch (e) {}
    }

    return JSON.stringify({ success: true, method: 'click_first' });

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
    function findNextBtn() {
      var candidates = document.querySelectorAll('.ui-pg-button[id^="next_"], [title="下一页"], .ui-icon-seek-next');
      for (var i = 0; i < candidates.length; i++) {
        var c = candidates[i];
        var btn = c.closest('.ui-pg-button') || c;
        if (btn && !btn.classList.contains('ui-state-disabled')) {
          return btn;
        }
      }
      return null;
    }

    var target = findNextBtn();
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
