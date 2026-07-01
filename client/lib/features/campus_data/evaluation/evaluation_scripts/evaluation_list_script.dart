library;

/// JavaScript to read the current state of the jqGrid list of evaluations.
String buildGetEvaluationListScript() {
  return '''
(function () {
  'use strict';
  try {
    var items = [];
    var table = document.querySelector('table.ui-jqgrid-btable');
    if (!table) {
      return JSON.stringify({ error: '未找到评价列表表格', items: [] });
    }

    var headerCells = document.querySelectorAll('.ui-jqgrid-htable th');
    var statusColIndex = -1;
    var courseColIndex = -1;
    var teacherColIndex = -1;

    for (var i = 0; i < headerCells.length; i++) {
      var ht = (headerCells[i].textContent || '').replace(/\\s+/g, '');
      if (ht.indexOf('状态') >= 0) statusColIndex = i;
      if (ht.indexOf('课程') >= 0) courseColIndex = i;
      if (ht.indexOf('教师') >= 0) teacherColIndex = i;
    }

    // fallback
    if (statusColIndex === -1) statusColIndex = 6; 

    var rows = table.querySelectorAll('tr.jqgrow');
    var currentPage = 1;
    var pageInput = document.querySelector('.ui-pg-input');
    if (pageInput) {
      currentPage = parseInt(pageInput.value, 10) || 1;
    }

    for (var i = 0; i < rows.length; i++) {
      var row = rows[i];
      var rowId = row.getAttribute('id') || '';
      var cells = row.querySelectorAll('td');
      
      var statusText = '';
      if (statusColIndex >= 0 && statusColIndex < cells.length) {
        statusText = cells[statusColIndex].textContent || '';
      }

      var fingerprint = rowId;
      if (courseColIndex >= 0 && courseColIndex < cells.length) {
        fingerprint += '|' + (cells[courseColIndex].textContent || '').trim();
      }
      if (teacherColIndex >= 0 && teacherColIndex < cells.length) {
        fingerprint += '|' + (cells[teacherColIndex].textContent || '').trim();
      }

      var isSelected = row.classList.contains('ui-state-highlight');

      items.push({
        safeId: 'row_' + i,
        rowId: rowId,
        fingerprint: fingerprint.substring(0, 100),
        selected: isSelected,
        status: statusText.trim(),
        page: currentPage
      });
    }

    return JSON.stringify({ items: items });
  } catch (e) {
    return JSON.stringify({ error: String(e), items: [] });
  }
})();
''';
}
