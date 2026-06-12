// 融智云考题目提取函数 - 供 Rod 无头浏览器调用
// 从浏览器油猴脚本提取，供服务端自动化使用

window.__queryWithFallback = function(selectors, context) {
    context = context || document;
    for (var i = 0; i < selectors.length; i++) {
        try {
            var el = context.querySelector(selectors[i]);
            if (el) return el;
        } catch(e) {}
    }
    return null;
};

window.__queryAllWithFallback = function(selectors, context) {
    context = context || document;
    var results = [];
    for (var i = 0; i < selectors.length; i++) {
        try {
            var nodes = context.querySelectorAll(selectors[i]);
            results = results.concat(Array.from(nodes));
        } catch(e) {}
    }
    return results.filter(function(v, i, a) { return a.indexOf(v) === i; });
};

// 提取当前页面上的一道题目
window.__extractCurrentQuestion = function() {
    var slideContent = window.__queryWithFallback([
        '.practice_slide_content.slide-con',
        '.practice_slide_content',
        '.slide-con',
        '.question-content'
    ]);

    if (!slideContent) return null;

    var q = {
        id: '',
        index: 0,
        question: '',
        questionType: '',
        chapter: '',
        options: [],
        answer: '',
        analysis: '',
        score: ''
    };

    q.id = slideContent.getAttribute('data-id') || '';
    var chapterId = slideContent.getAttribute('data-chapterid') || '';

    // 题号
    var currentEl = window.__queryWithFallback([
        '.on[data-questioncount]',
        '.active[data-questioncount]',
        '[data-questioncount].on'
    ]);
    if (currentEl) {
        q.index = parseInt(currentEl.getAttribute('data-questioncount')) || 0;
    }

    // 题目文本
    var titleEl = window.__queryWithFallback([
        '.practice_slide_title .title',
        '.question-title',
        '.title',
        'h3.title'
    ], slideContent);
    if (titleEl) q.question = titleEl.textContent.trim();

    // 题型
    var typeEl = window.__queryWithFallback([
        '.practice_slide_title .type',
        '.question-type',
        '.type'
    ], slideContent);
    if (typeEl) q.questionType = typeEl.textContent.trim();

    // 分值
    if (q.questionType.indexOf('单选') >= 0 || q.questionType.indexOf('判断') >= 0) {
        q.score = '1.0';
    } else if (q.questionType.indexOf('多选') >= 0) {
        q.score = '2.0';
    }

    // 章节
    if (chapterId) {
        var chapterSel = document.querySelector('#chapter');
        if (chapterSel) {
            var opt = chapterSel.querySelector('option[value="' + chapterId + '"]');
            if (opt) q.chapter = opt.textContent.trim();
        }
    }

    // 选项 + 答案
    if (q.questionType.indexOf('单选') >= 0 || q.questionType.indexOf('多选') >= 0) {
        var optionEls = window.__queryAllWithFallback([
            '.option_content li',
            '.options li',
            '.answer-list li'
        ], slideContent);

        var correctAnswers = [];
        optionEls.forEach(function(li) {
            var letterEl = window.__queryWithFallback(['.letterArr', '.letter', 'span:first-child'], li);
            var textEl = window.__queryWithFallback(['.txt', '.text', '.option-text'], li);
            var inputEl = li.querySelector('input[data-isright="1"]') || li.querySelector('[data-isright="1"]');

            if (letterEl && textEl) {
                var label = letterEl.textContent.trim();
                q.options.push({ label: label, text: textEl.textContent.trim() });
                if (inputEl) {
                    var isRight = inputEl.getAttribute('data-isright') || inputEl.getAttribute('data-correct');
                    if (isRight === '1' || isRight === 'true') correctAnswers.push(label);
                }
            }
        });
        q.answer = correctAnswers.join('');

        // 备选：从答案显示区获取
        if (!q.answer) {
            var ansText = window.__queryWithFallback([
                '.answer-text', '.answer-show', '.correct-answer'
            ], slideContent);
            if (ansText) q.answer = ansText.textContent.trim().replace(/^答案：?/, '');
        }
    } else if (q.questionType.indexOf('判断') >= 0) {
        var correctInput = slideContent.querySelector('input[data-isright="1"]') || slideContent.querySelector('[data-correct="1"]');
        if (correctInput) {
            var parentLi = correctInput.closest('li');
            if (parentLi) {
                var idx = Array.from(parentLi.parentElement.children).indexOf(parentLi);
                q.answer = idx === 0 ? '正确' : '错误';
            }
        }
        if (!q.answer) {
            var ansText = window.__queryWithFallback(['.answer-text', '.answer-show', '.correct-answer'], slideContent);
            if (ansText) {
                var v = ansText.textContent.trim();
                q.answer = (v === 'A' || v === '对') ? '正确' : '错误';
            }
        }
    } else if (q.questionType.indexOf('填空') >= 0) {
        var ansEls = window.__queryAllWithFallback(['.answer-input-result', '.fill-answer'], slideContent);
        var answers = [];
        ansEls.forEach(function(e) {
            var t = e.textContent.trim();
            if (t && t !== '?' && t !== '空') answers.push(t);
        });
        q.answer = answers.join('；');
    }

    // 解析
    var analysisEl = window.__queryWithFallback([
        '.analysis-content .desc',
        '.analysis .desc',
        '.answer-analysis',
        '.analysis'
    ], slideContent);
    if (analysisEl) q.analysis = analysisEl.textContent.trim();

    return q;
};

// 获取题目总数
window.__getTotalQuestions = function() {
    var all = document.querySelectorAll('[data-questioncount]');
    if (all.length > 0) return all.length;
    var urlParams = new URLSearchParams(window.location.search);
    return parseInt(urlParams.get('studentpractisequestioncount')) || 200;
};

// 点击下一题按钮
window.__clickNext = function() {
    var nextBtn = window.__queryWithFallback([
        '.swiper-button-next',
        '.next-btn',
        '.btn-next',
        '[data-action="next"]'
    ]);
    if (nextBtn && !nextBtn.classList.contains('swiper-button-disabled') && !nextBtn.disabled) {
        nextBtn.click();
        return true;
    }
    return false;
};

// 等待题目切换完成
window.__waitForQuestionChange = function(currentIndex, timeoutMs) {
    timeoutMs = timeoutMs || 5000;
    return new Promise(function(resolve) {
        var start = Date.now();
        var check = setInterval(function() {
            var el = window.__queryWithFallback([
                '.on[data-questioncount]',
                '.active[data-questioncount]'
            ]);
            if (el) {
                var idx = parseInt(el.getAttribute('data-questioncount'));
                if (idx !== currentIndex) {
                    clearInterval(check);
                    resolve(idx);
                    return;
                }
            }
            if (Date.now() - start > timeoutMs) {
                clearInterval(check);
                resolve(0);
            }
        }, 100);
    });
};

// 用async/await包装，确保脚本注入后可用
window.__extractAllQuestions = async function() {
    var total = window.__getTotalQuestions();
    var questions = [];
    
    // 提取第一题
    var first = window.__extractCurrentQuestion();
    if (first) questions.push(first);
    
    for (var i = (first ? first.index + 1 : 2); i <= total; i++) {
        var clicked = window.__clickNext();
        if (!clicked) break;
        
        var newIdx = await window.__waitForQuestionChange(i - 1, 3000);
        if (newIdx === 0) break;
        
        await new Promise(function(r) { setTimeout(r, 400); });
        
        var q = window.__extractCurrentQuestion();
        if (q) questions.push(q);
    }
    
    return JSON.stringify(questions);
};
