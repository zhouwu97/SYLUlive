// ==UserScript==
// @name         融智云考练习题提取器
// @namespace    http://tampermonkey.net/
// @version      6.1
// @description  自动提取融智云考系统的练习题目
// @author       Assistant
// @match        https://www.cctrcloud.net/practice/subject_practice.html*
// @match        https://kwk.ahau.edu.cn/practice/subject_practice.html*
// @grant        none
// @run-at       document-end
// ==/UserScript==

(function() {
    'use strict';

    // ========== 调试开关 ==========
    const DEBUG = true;
    function log(...args) { if (DEBUG) console.log('[提取器]', ...args); }

    // 创建样式
    const style = document.createElement('style');
    style.textContent = `
        @keyframes pulse {
            0% { transform: scale(1); }
            50% { transform: scale(1.05); }
            100% { transform: scale(1); }
        }

        @keyframes slideIn {
            from {
                opacity: 0;
                transform: translate(-50%, -60%);
            }
            to {
                opacity: 1;
                transform: translate(-50%, -50%);
            }
        }

        @keyframes gradient {
            0% { background-position: 0% 50%; }
            50% { background-position: 100% 50%; }
            100% { background-position: 0% 50%; }
        }

        .extract-button-float {
            animation: pulse 2s infinite;
        }

        .extract-panel-show {
            animation: slideIn 0.3s ease-out;
        }
    `;
    document.head.appendChild(style);

    // 创建浮动按钮
    const floatButton = document.createElement('div');
    floatButton.className = 'extract-button-float';
    floatButton.innerHTML = '提取<br>题目';
    floatButton.style.cssText = `
        position: fixed;
        bottom: 30px;
        right: 30px;
        width: 70px;
        height: 70px;
        background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
        color: white;
        border-radius: 50%;
        display: flex;
        flex-direction: column;
        align-items: center;
        justify-content: center;
        cursor: pointer;
        z-index: 99999;
        font-weight: bold;
        font-size: 14px;
        line-height: 1.2;
        text-align: center;
        box-shadow: 0 8px 32px rgba(102, 126, 234, 0.4);
        transition: all 0.3s ease;
        backdrop-filter: blur(4px);
        border: 1px solid rgba(255, 255, 255, 0.18);
    `;

    floatButton.onmouseover = () => {
        floatButton.style.transform = 'scale(1.1) rotate(5deg)';
        floatButton.style.boxShadow = '0 12px 40px rgba(102, 126, 234, 0.6)';
    };
    floatButton.onmouseout = () => {
        floatButton.style.transform = 'scale(1) rotate(0deg)';
        floatButton.style.boxShadow = '0 8px 32px rgba(102, 126, 234, 0.4)';
    };

    document.body.appendChild(floatButton);

    // 创建提取界面
    const extractPanel = document.createElement('div');
    extractPanel.id = 'extract-panel';
    extractPanel.style.cssText = `
        position: fixed;
        top: 50%;
        left: 50%;
        transform: translate(-50%, -50%);
        width: 450px;
        background: rgba(255, 255, 255, 0.95);
        backdrop-filter: blur(10px);
        border-radius: 20px;
        padding: 0;
        z-index: 100000;
        box-shadow: 0 20px 60px rgba(0, 0, 0, 0.3);
        display: none;
        overflow: hidden;
        border: 1px solid rgba(255, 255, 255, 0.3);
    `;

    // ========== 多重选择器工具函数 ==========
    function $(selector, context = document) {
        return context.querySelector(selector);
    }

    function $$(selector, context = document) {
        return Array.from(context.querySelectorAll(selector));
    }

    // 尝试多个选择器，返回第一个匹配的元素
    function queryWithFallback(selectors, context = document) {
        const list = Array.isArray(selectors) ? selectors : [selectors];
        for (const sel of list) {
            try {
                const el = context.querySelector(sel);
                if (el) return el;
            } catch (e) { /* invalid selector, skip */ }
        }
        return null;
    }

    // 尝试多个选择器，返回所有匹配的元素
    function queryAllWithFallback(selectors, context = document) {
        const list = Array.isArray(selectors) ? selectors : [selectors];
        let results = [];
        for (const sel of list) {
            try {
                results = results.concat(Array.from(context.querySelectorAll(sel)));
            } catch (e) { /* invalid selector, skip */ }
        }
        // 去重
        return [...new Set(results)];
    }

    // 获取当前题目信息
    function getCurrentQuestionInfo() {
        // 尝试多种可能的选择器
        const currentElement = queryWithFallback([
            '.on[data-questioncount]',
            '.active[data-questioncount]',
            '[data-questioncount].on',
            '.swiper-slide.active [data-questioncount]',
            '.question-item.active'
        ]);

        const allQuestions = queryWithFallback([
            '[data-questioncount]',
            '.question-item',
            '.swiper-slide'
        ]);

        const totalFromDOM = allQuestions ? (queryWithFallback(['[data-questioncount]', '.question-item'], allQuestions.parentElement) ?
            allQuestions.parentElement.querySelectorAll('[data-questioncount]').length :
            (allQuestions.length || 0)) : 0;

        if (currentElement) {
            const current = parseInt(currentElement.getAttribute('data-questioncount')) ||
                           parseInt(currentElement.dataset.questioncount);
            const total = totalFromDOM || $$('[data-questioncount]').length;
            log(`当前题目: ${current}, 总数: ${total}`);
            return { current, total: total || 200 };
        }

        const urlParams = new URLSearchParams(window.location.search);
        const total = parseInt(urlParams.get('studentpractisequestioncount')) ||
                     parseInt(urlParams.get('total')) || 200;
        log(`无法从DOM获取，使用URL参数: ${total}`);
        return { current: 1, total };
    }

    const questionInfo = getCurrentQuestionInfo();

    extractPanel.innerHTML = `
        <div style="background: linear-gradient(135deg, #667eea 0%, #764ba2 100%); padding: 25px; color: white;">
            <h2 style="margin: 0; font-size: 24px; font-weight: 300;">
                ✨ 练习题智能提取器
            </h2>
        </div>
        
        <div style="padding: 30px;">
            <div style="background: linear-gradient(135deg, #f5f7fa 0%, #c3cfe2 100%); border-radius: 15px; padding: 20px; margin-bottom: 25px;">
                <div style="display: grid; grid-template-columns: repeat(3, 1fr); gap: 15px; text-align: center;">
                    <div>
                        <div style="font-size: 24px; font-weight: bold; color: #667eea;" id="current-question">${questionInfo.current}</div>
                        <div style="font-size: 12px; color: #666; margin-top: 5px;">当前题目</div>
                    </div>
                    <div>
                        <div style="font-size: 24px; font-weight: bold; color: #764ba2;" id="total-questions">${questionInfo.total}</div>
                        <div style="font-size: 12px; color: #666; margin-top: 5px;">总题目数</div>
                    </div>
                    <div>
                        <div style="font-size: 24px; font-weight: bold; color: #f093fb;" id="remaining-questions">${questionInfo.total - questionInfo.current + 1}</div>
                        <div style="font-size: 12px; color: #666; margin-top: 5px;">待提取</div>
                    </div>
                </div>
            </div>
            
            <div id="extract-status" style="
                text-align: center;
                padding: 15px;
                background: #f8f9fa;
                border-radius: 10px;
                margin-bottom: 20px;
                font-size: 14px;
                color: #333;
                display: flex;
                align-items: center;
                justify-content: center;
                min-height: 50px;
            ">
                ✅ 准备就绪，点击开始提取
            </div>
            
            <div id="extract-progress" style="margin-bottom: 25px;">
                <div style="background: #e9ecef; height: 30px; border-radius: 15px; overflow: hidden; position: relative;">
                    <div id="progress-bar" style="
                        width: 0%;
                        height: 100%;
                        background: linear-gradient(90deg, #667eea 0%, #764ba2 100%);
                        transition: width 0.3s ease;
                        position: relative;
                        overflow: hidden;
                    ">
                        <div style="
                            position: absolute;
                            top: 0;
                            left: 0;
                            right: 0;
                            bottom: 0;
                            background: linear-gradient(
                                45deg,
                                rgba(255,255,255,.2) 25%,
                                transparent 25%,
                                transparent 50%,
                                rgba(255,255,255,.2) 50%,
                                rgba(255,255,255,.2) 75%,
                                transparent 75%,
                                transparent
                            );
                            background-size: 40px 40px;
                            animation: progress-bar-stripes 1s linear infinite;
                        "></div>
                    </div>
                    <div style="
                        position: absolute;
                        top: 50%;
                        left: 50%;
                        transform: translate(-50%, -50%);
                        font-weight: bold;
                        color: #333;
                        font-size: 14px;
                    " id="progress-text">0 / ${questionInfo.total}</div>
                </div>
            </div>
            
            <div style="display: flex; gap: 10px;">
                <button id="start-extract" style="
                    flex: 1;
                    padding: 15px;
                    background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
                    color: white;
                    border: none;
                    border-radius: 10px;
                    cursor: pointer;
                    font-size: 16px;
                    font-weight: bold;
                    transition: all 0.3s;
                    box-shadow: 0 4px 15px rgba(102, 126, 234, 0.4);
                ">
                    ▶ 开始提取
                </button>
                
                <button id="stop-extract" style="
                    flex: 1;
                    padding: 15px;
                    background: linear-gradient(135deg, #f093fb 0%, #f5576c 100%);
                    color: white;
                    border: none;
                    border-radius: 10px;
                    cursor: pointer;
                    font-size: 16px;
                    font-weight: bold;
                    transition: all 0.3s;
                    box-shadow: 0 4px 15px rgba(245, 87, 108, 0.4);
                    display: none;
                ">
                    ⏸ 停止提取
                </button>
                
                <button id="close-panel" style="
                    padding: 15px 25px;
                    background: #e9ecef;
                    color: #495057;
                    border: none;
                    border-radius: 10px;
                    cursor: pointer;
                    font-size: 16px;
                    transition: all 0.3s;
                ">
                    ✕
                </button>
            </div>
        </div>
        
        <style>
            @keyframes progress-bar-stripes {
                from { background-position: 40px 0; }
                to { background-position: 0 0; }
            }
            
            #start-extract:hover {
                transform: translateY(-2px);
                box-shadow: 0 6px 20px rgba(102, 126, 234, 0.5);
            }
            
            #stop-extract:hover {
                transform: translateY(-2px);
                box-shadow: 0 6px 20px rgba(245, 87, 108, 0.5);
            }
            
            #close-panel:hover {
                background: #dee2e6;
            }
        </style>
    `;
    document.body.appendChild(extractPanel);

    // 提取状态
    let isExtracting = false;
    let stopExtraction = false;

    // 显示/隐藏面板
    floatButton.onclick = () => {
        if (extractPanel.style.display === 'none') {
            extractPanel.style.display = 'block';
            extractPanel.classList.add('extract-panel-show');
            // 更新当前题目信息
            const info = getCurrentQuestionInfo();
            document.getElementById('current-question').textContent = info.current;
            document.getElementById('total-questions').textContent = info.total;
            document.getElementById('remaining-questions').textContent = info.total - info.current + 1;
        } else {
            extractPanel.style.display = 'none';
        }
    };

    document.getElementById('close-panel').onclick = () => {
        extractPanel.style.display = 'none';
    };

    // ========== 智能等待函数 ==========
    function waitForElement(selectors, timeout = 5000) {
        return new Promise((resolve) => {
            const list = Array.isArray(selectors) ? selectors : [selectors];

            // 先检查是否已经存在
            for (const sel of list) {
                try {
                    const el = document.querySelector(sel);
                    if (el) {
                        log(`元素已存在: ${sel}`);
                        resolve(el);
                        return;
                    }
                } catch (e) {}
            }

            // 使用 MutationObserver 监听变化
            const observer = new MutationObserver(() => {
                for (const sel of list) {
                    try {
                        const el = document.querySelector(sel);
                        if (el) {
                            observer.disconnect();
                            log(`元素已出现: ${sel}`);
                            resolve(el);
                            return;
                        }
                    } catch (e) {}
                }
            });

            observer.observe(document.body, { childList: true, subtree: true });

            // 超时处理
            setTimeout(() => {
                observer.disconnect();
                log(`等待元素超时: ${list.join(', ')}`);
                resolve(null);
            }, timeout);
        });
    }

    // ========== 诊断函数 ==========
    window.runExtractionDiagnostic = async function() {
        console.log('========== 提取器诊断 ==========');
        console.log('URL:', window.location.href);

        const tests = [
            { name: '题目容器', selectors: ['.practice_slide_content.slide-con', '.practice_slide_content', '.slide-con', '.question-container', '.exam-question'] },
            { name: '当前题目标记', selectors: ['.on[data-questioncount]', '.active[data-questioncount]', '[data-questioncount].on', '.current-question'] },
            { name: '下一题按钮', selectors: ['.swiper-button-next', '.next-btn', '.btn-next', '[data-action="next"]', '.slick-next'] },
            { name: '题目标题', selectors: ['.practice_slide_title .title', '.question-title', '.title', 'h3.title'] },
            { name: '题型标签', selectors: ['.practice_slide_title .type', '.question-type', '.type', '.tag-type'] },
            { name: '选项列表', selectors: ['.option_content li', '.options li', '.answer-list li', '.choice-item'] },
            { name: '正确答案标记', selectors: ['input[data-isright="1"]', '[data-isright="1"]', '.correct-input', '.is-right'] },
            { name: '答案显示区', selectors: ['.answer-text', '.answer-show', '.correct-answer', '.result-answer'] },
            { name: '解析内容', selectors: ['.analysis-content .desc', '.analysis', '.answer-analysis', '.analysis-desc'] }
        ];

        for (const test of tests) {
            const result = queryWithFallback(test.selectors);
            console.log(`${test.name}: ${result ? '✓ 找到' : '✗ 未找到'}`,
                result ? `(${test.selectors.find(s => document.querySelector(s) === result)})` : '');
        }

        console.log('================================');
        return tests.map(t => ({ name: t.name, found: !!queryWithFallback(t.selectors) }));
    };

    // 获取单个题目数据的函数
        // 辅助函数：把 SVG data URI 转换为 PNG data URI，彻底解决 Word 不支持复制 SVG 的问题
    function svgToPngDataURL(svgUri) {
        return new Promise((resolve) => {
            const img = new Image();
            
            const timeoutId = setTimeout(() => {
                resolve(svgUri);
            }, 2000);

            img.onload = () => {
                clearTimeout(timeoutId);
                try {
                    const canvas = document.createElement('canvas');
                    canvas.width = img.width || 100;
                    canvas.height = img.height || 30;
                    const ctx = canvas.getContext('2d');
                    ctx.drawImage(img, 0, 0);
                    resolve(canvas.toDataURL('image/png'));
                } catch(e) {
                    resolve(svgUri);
                }
            };
            img.onerror = () => {
                clearTimeout(timeoutId);
                resolve(svgUri);
            };
            img.src = svgUri;
        });
    }

    async function getRichText(element) {
        if (!element) return '';
        const clone = element.cloneNode(true);
        
        clone.querySelectorAll('.MathJax, mjx-container, .katex').forEach(container => {
            const mathML = container.querySelector('.MJX_Assistive_MathML math, mjx-assistive-mml math, .katex-mathml math, math');
            if (mathML) {
                mathML.setAttribute('xmlns', 'http://www.w3.org/1998/Math/MathML');
                container.parentNode.insertBefore(mathML, container);
                container.remove();
            } else {
                const texScript = container.parentNode.querySelector('script[type^=\'math/tex\']');
                if (texScript) {
                    const textNode = document.createTextNode(' ' + texScript.textContent + ' ');
                    container.parentNode.insertBefore(textNode, container);
                    container.remove();
                }
            }
        });

        clone.querySelectorAll('.MathJax_Preview').forEach(el => el.remove());

        const imgPromises = Array.from(clone.querySelectorAll('img')).map(async (img) => {
            const realSrc = img.getAttribute('data-src') || img.getAttribute('fr-original-src') || img.src;
            if (realSrc) {
                let finalSrc = realSrc;
                if (finalSrc.startsWith('/')) {
                    finalSrc = window.location.origin + finalSrc;
                } else if (!finalSrc.startsWith('http') && !finalSrc.startsWith('data:')) {
                    const path = window.location.pathname.substring(0, window.location.pathname.lastIndexOf('/') + 1);
                    finalSrc = window.location.origin + path + finalSrc;
                }
                
                if (finalSrc.startsWith('http://')) {
                    finalSrc = finalSrc.replace('http://', 'https://');
                }

                if (finalSrc.startsWith('data:image/svg+xml')) {
                    try {
                        const svgStr = finalSrc.includes('base64,') ? 
                            atob(finalSrc.split('base64,')[1]) : 
                            decodeURIComponent(finalSrc.split(',')[1]);
                        const doc = new DOMParser().parseFromString(svgStr, 'image/svg+xml');
                        const math = doc.querySelector('math');
                        if (math) {
                            math.setAttribute('xmlns', 'http://www.w3.org/1998/Math/MathML');
                            img.parentNode.insertBefore(math, img);
                            img.remove();
                            return;
                        }
                    } catch(e) {}
                    finalSrc = await svgToPngDataURL(finalSrc);
                }

                img.setAttribute('src', finalSrc);
            }
            img.style.verticalAlign = 'middle';
            img.style.maxWidth = '100%';
        });
        
        await Promise.all(imgPromises);
        return clone.innerHTML.trim().replace(/[\u200B-\u200D\uFEFF]/g, '');
    }

    async function extractCurrentQuestion() {
        const slideContent = queryWithFallback([
            '.practice_slide_content.slide-con',
            '.practice_slide_content',
            '.slide-con',
            '.question-content',
            '.practice-slide',
            '[class*="question"]',
            '[class*="slide"]'
        ]);

        if (!slideContent) {
            log('未找到题目容器');
            return null;
        }

        const question = {
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

        // 获取题目ID和章节ID
        question.id = slideContent.getAttribute('data-id') ||
                     slideContent.getAttribute('data-question-id') || '';

        const chapterId = slideContent.getAttribute('data-chapterid') ||
                         slideContent.getAttribute('data-chapter-id') || '';

        // 获取题目编号 - 多种方式
        const currentQuestionElement = queryWithFallback([
            '.on[data-questioncount]',
            '.active[data-questioncount]',
            '[data-questioncount].on',
            '.current',
            '.active'
        ]);

        if (currentQuestionElement) {
            question.index = parseInt(currentQuestionElement.getAttribute('data-questioncount')) ||
                           parseInt(currentQuestionElement.dataset.questioncount) ||
                           parseInt(currentQuestionElement.textContent.match(/\d+/)?.[0]) || 0;
        }

        // 获取题目内容 - 多种选择器
        const questionElement = queryWithFallback([
            '.practice_slide_title .title',
            '.question-title',
            '.title',
            'h3.title',
            '.question-text',
            '[class*="title"]'
        ], slideContent);
        if (questionElement) {
            question.question = await getRichText(questionElement);
        }

        // 获取题型
        const typeElement = queryWithFallback([
            '.practice_slide_title .type',
            '.question-type',
            '.type',
            '.tag-type',
            '[class*="type"]'
        ], slideContent);
        if (typeElement) {
            question.questionType = typeElement.textContent.trim();
        }

        // 获取章节（从select选项中查找）
        if (chapterId) {
            const chapterOption = queryWithFallback(['#chapter', '.chapter-select', 'select[name*="chapter"]'])
                .querySelector(`option[value="${chapterId}"]`);
            if (chapterOption) {
                question.chapter = chapterOption.textContent.trim();
            }
        }

        // 根据题型设置分值
        if (question.questionType === '单选题' || question.questionType === '判断题') {
            question.score = '1.0';
        } else if (question.questionType === '多选题') {
            question.score = '2.0';
        }

        // 提取选项和答案
        if (question.questionType === '单选题' || question.questionType === '多选题') {
            const optionElements = queryAllWithFallback([
                '.option_content li',
                '.options li',
                '.answer-list li',
                '.choice-item',
                'li[class*="option"]'
            ], slideContent);

            const correctAnswers = [];

            optionElements.forEach((li) => {
                const letterElement = queryWithFallback(['.letterArr', '.letter', '.option-letter', 'span:first-child'], li);
                const textElement = queryWithFallback(['.txt', '.text', '.option-text', '.content'], li);
                const inputElement = queryWithFallback([
                    'input[data-isright="1"]',
                    'input[data-correct]',
                    '[data-isright="1"]',
                    '.correct'
                ], li);

                if (letterElement && textElement) {
                    const optionLabel = letterElement.textContent.trim();
                    const optionContent = await getRichText(textElement);
                    question.options.push({
                        label: optionLabel,
                        text: optionContent
                    });

                    // 检查是否为正确答案
                    if (inputElement) {
                        const isRight = inputElement.getAttribute('data-isright') ||
                                       inputElement.getAttribute('data-correct');
                        if (isRight === '1' || isRight === 'true') {
                            correctAnswers.push(optionLabel);
                        }
                    }
                }
            });

            question.answer = correctAnswers.join('');

            // 如果没有找到正确答案，尝试从答案显示区域获取
            if (!question.answer) {
                const answerText = queryWithFallback([
                    '.answer-text',
                    '.answer-show',
                    '.correct-answer',
                    '.result-answer',
                    '[class*="answer"]'
                ], slideContent);
                if (answerText) {
                    question.answer = await getRichText(answerText); question.answer = question.answer.replace(/^答案：?/, '');
                }
            }
        } else if (question.questionType === '判断题') {
            // 判断题的特殊处理
            const correctInput = queryWithFallback([
                'input[data-isright="1"]',
                '[data-correct="1"]',
                '.correct'
            ], slideContent);

            if (correctInput) {
                const parentLi = correctInput.closest('li');
                if (parentLi) {
                    const index = Array.from(parentLi.parentElement.children).indexOf(parentLi);
                    question.answer = index === 0 ? '正确' : '错误';
                }
            }

            // 备选方案：从答案显示区域获取
            if (!question.answer) {
                const answerText = queryWithFallback([
                    '.answer-text',
                    '.answer-show',
                    '.correct-answer'
                ], slideContent);
                if (answerText) {
                    const answerValue = answerText.textContent.trim();
                    if (answerValue === 'A' || answerValue === '对' || answerValue === '正确') {
                        question.answer = '正确';
                    } else if (answerValue === 'B' || answerValue === '错' || answerValue === '错误') {
                        question.answer = '错误';
                    }
                }
            }
        } else if (question.questionType === '填空题') {
            // 填空题答案提取
            const answerElements = queryAllWithFallback([
                '.answer-input-result',
                '.fill-answer',
                '.blank-answer',
                '[class*="answer"]'
            ], slideContent);
            const answers = [];
            answerElements.forEach(elem => {
                const text = await getRichText(elem);
                if (text && text !== '?' && text !== '空') answers.push(text);
            });
            question.answer = answers.join('；');

            // 备选方案
            if (!question.answer) {
                const answerText = queryWithFallback([
                    '.answer-text',
                    '.answer-show'
                ], slideContent);
                if (answerText) {
                    question.answer = await getRichText(answerText);
                }
            }
        }

        // 提取解析
        const analysisElement = queryWithFallback([
            '.analysis-content .desc',
            '.analysis .desc',
            '.answer-analysis',
            '.analysis',
            '[class*="analysis"]'
        ], slideContent);
        if (analysisElement) {
            question.analysis = await getRichText(analysisElement);
        }

        // 调试日志
        log(`提取题目 #${question.index}:`, question.questionType, question.question.substring(0, 30) + '...');

        return question;
    }

    // 更新状态显示
    function updateStatus(text, type = 'info') {
        const status = document.getElementById('extract-status');
        let icon = '';
        
        switch(type) {
            case 'success':
                icon = '✅ ';
                break;
            case 'error':
                icon = '❌ ';
                break;
            case 'loading':
                icon = '⏳ ';
                break;
            default:
                icon = 'ℹ️ ';
        }
        
        status.textContent = icon + text;
    }

    // ========== 智能等待内容加载 ==========
    let lastQuestionIndex = 0;
    const observerCallback = (mutations) => {
        // 检测题目是否切换
        const currentQ = queryWithFallback(['.on[data-questioncount]', '.active[data-questioncount]']);
        if (currentQ) {
            const idx = parseInt(currentQ.getAttribute('data-questioncount'));
            if (idx !== lastQuestionIndex) {
                lastQuestionIndex = idx;
                log(`题目切换到: ${idx}`);
            }
        }
    };
    const contentObserver = new MutationObserver(observerCallback);

    async function waitForContentChange(timeout = 3000) {
        return new Promise((resolve) => {
            const startTime = Date.now();
            const originalIndex = lastQuestionIndex;

            // 轮询方式检测变化
            const checkInterval = setInterval(() => {
                if (stopExtraction) {
                    clearInterval(checkInterval);
                    resolve(false);
                    return;
                }

                if (Date.now() - startTime > timeout) {
                    clearInterval(checkInterval);
                    resolve(false);
                    return;
                }

                // 检测是否切换到新题目
                const currentQ = queryWithFallback(['.on[data-questioncount]', '.active[data-questioncount]']);
                if (currentQ) {
                    const idx = parseInt(currentQ.getAttribute('data-questioncount'));
                    if (idx !== originalIndex) {
                        clearInterval(checkInterval);
                        resolve(true);
                    }
                }
            }, 100);
        });
    }

    // 开始提取
    document.getElementById('start-extract').onclick = async () => {
        if (isExtracting) return;

        // 启动内容观察器
        contentObserver.observe(document.body, { childList: true, subtree: true });

        isExtracting = true;
        stopExtraction = false;

        const startBtn = document.getElementById('start-extract');
        const stopBtn = document.getElementById('stop-extract');
        startBtn.style.display = 'none';
        stopBtn.style.display = 'block';

        const progressBar = document.getElementById('progress-bar');
        const progressText = document.getElementById('progress-text');

        const questions = [];
        const questionInfo = getCurrentQuestionInfo();
        const startIndex = questionInfo.current;
        const totalQuestions = questionInfo.total;

        log(`开始提取: 从${startIndex}题到${totalQuestions}题`);

        updateStatus(`正在提取题目...从第 ${startIndex} 题开始`, 'loading');

        // 先提取当前题目
        const currentQuestion = await extractCurrentQuestion();
        if (currentQuestion) {
            questions.push(currentQuestion);
            log(`提取第 ${startIndex} 题:`, currentQuestion);
            const progress = ((startIndex / totalQuestions) * 100).toFixed(1);
            progressBar.style.width = progress + '%';
            progressText.textContent = `${startIndex} / ${totalQuestions}`;
        } else {
            log('警告: 无法提取当前题目');
            updateStatus('无法提取当前题目，请检查诊断 (Ctrl+Shift+E 打开面板)', 'error');
        }

        // 提取后续题目
        for (let i = startIndex + 1; i <= totalQuestions && !stopExtraction; i++) {
            // 尝试多种下一题按钮选择器
            const nextButton = queryWithFallback([
                '.swiper-button-next',
                '.next-btn',
                '.btn-next',
                '[data-action="next"]',
                '.slick-next',
                '[class*="next"]',
                'button.next'
            ]);

            if (!nextButton) {
                log('未找到下一题按钮');
                updateStatus('未找到下一题按钮，尝试手动切换', 'error');
                break;
            }

            if (nextButton.classList.contains('swiper-button-disabled') ||
                nextButton.disabled ||
                nextButton.getAttribute('aria-disabled') === 'true') {
                log('下一题按钮禁用');
                break;
            }

            // 记录点击前的题目索引
            const beforeClick = lastQuestionIndex || (startIndex);

            // 点击下一题
            log(`点击下一题按钮 (${i}/${totalQuestions})`);
            nextButton.click();

            // 智能等待内容变化，最多等3秒
            const changed = await waitForContentChange(3000);
            if (!changed && i > startIndex + 1) {
                log('等待内容变化超时，尝试继续...');
            }

            // 额外等待动画/渲染完成
            await new Promise(r => setTimeout(r, 300));

            // 提取题目
            const question = await extractCurrentQuestion();
            if (question) {
                questions.push(question);
                log(`提取第 ${i} 题成功:`, question.questionType);
            } else {
                log(`提取第 ${i} 题失败`);
            }

            // 更新进度
            const progress = ((i / totalQuestions) * 100).toFixed(1);
            progressBar.style.width = progress + '%';
            progressText.textContent = `${i} / ${totalQuestions}`;
            updateStatus(`正在提取第 ${i} 题... (${questions.length}已提取)`, 'loading');
        }

        // 停止观察器
        contentObserver.disconnect();

        if (stopExtraction) {
            updateStatus(`已停止提取，共提取了 ${questions.length} 道题`, 'error');
        } else {
            updateStatus(`提取完成！共提取了 ${questions.length} 道题`, 'success');
        }

        // 下载JSON文件
        if (questions.length > 0) {
            const dataStr = JSON.stringify(questions, null, 2);
            const dataBlob = new Blob([dataStr], {type: 'application/json'});
            const url = URL.createObjectURL(dataBlob);
            const link = document.createElement('a');
            const courseName = new URLSearchParams(window.location.search).get('coursename') || 'practice';
            link.href = url;
            link.download = `exam_questions_${courseName}_从${startIndex}题开始_${new Date().getTime()}.json`;
            link.click();
            URL.revokeObjectURL(url);

            setTimeout(() => {
                updateStatus('文件已下载，可以关闭窗口了', 'success');
            }, 1000);
        }

        isExtracting = false;
        startBtn.style.display = 'block';
        stopBtn.style.display = 'none';
    };

    // 停止提取
    document.getElementById('stop-extract').onclick = () => {
        stopExtraction = true;
        updateStatus('正在停止...', 'loading');
    };

    // 添加快捷键支持
    document.addEventListener('keydown', (e) => {
        if (e.ctrlKey && e.shiftKey && e.key === 'E') {
            floatButton.click();
        }
    });

    // 添加旋转动画的CSS
    const spinStyle = document.createElement('style');
    spinStyle.textContent = `
        @keyframes spin {
            from { transform: rotate(0deg); }
            to { transform: rotate(360deg); }
        }
    `;
    document.head.appendChild(spinStyle);

    console.log('✨ 融智云考练习题提取器 v6.1 已加载！');
    console.log('按 Ctrl+Shift+E 可快速打开/关闭界面');
    console.log('在控制台运行 window.runExtractionDiagnostic() 可诊断问题');
})(); 
