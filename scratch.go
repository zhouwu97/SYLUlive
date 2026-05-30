	jsCode := `(function() {
    window.__aiExamData = null;
    window.__aiSnapshotBackedUp = false;

    function parseRange(str) {
        let indices = new Set();
        let parts = str.split(/[,，\s]+/);
        parts.forEach(part => {
            if (!part) return;
            if (part.includes('-') || part.includes('~')) {
                let bounds = part.split(/[-~]/);
                let start = parseInt(bounds[0], 10);
                let end = parseInt(bounds[1], 10);
                if (!isNaN(start) && !isNaN(end)) {
                    for(let i = Math.min(start, end); i <= Math.max(start, end); i++) indices.add(i);
                }
            } else {
                let num = parseInt(part, 10);
                if (!isNaN(num)) indices.add(num);
            }
        });
        return Array.from(indices).sort((a,b)=>a-b);
    }

    function injectDashboard() {
        if (document.getElementById('ai-cheat-host')) return document.getElementById('ai-cheat-host')._dashInterface;
        const host = document.createElement('div');
        host.id = 'ai-cheat-host';
        host.style.cssText = 'position: fixed; top: 20px; left: 10px; width: calc(100% - 20px); max-width: 400px; z-index: 999999; pointer-events: none;';
        const shadow = host.attachShadow({mode: 'closed'});
        
        shadow.innerHTML = \`
            <style>
                :host { all: initial; }
                * { box-sizing: border-box; }
                .dashboard {
                    pointer-events: auto;
                    font-family: system-ui, -apple-system, sans-serif;
                    background: rgba(20, 20, 25, 0.95);
                    border: 1px solid rgba(255,255,255,0.15);
                    backdrop-filter: blur(12px);
                    color: white;
                    border-radius: 12px;
                    box-shadow: 0 10px 40px rgba(0,0,0,0.6);
                    display: flex;
                    flex-direction: column;
                    overflow: hidden;
                }
                .header {
                    padding: 12px 15px;
                    background: rgba(255,255,255,0.08);
                    border-bottom: 1px solid rgba(255,255,255,0.1);
                    display: flex;
                    justify-content: space-between;
                    align-items: center;
                    cursor: move;
                    touch-action: none;
                }
                .header-title { font-size: 14px; font-weight: 600; color: #4CAF50; letter-spacing: 0.5px; }
                .header-actions span { margin-left: 15px; font-size: 12px; cursor: pointer; color: #aaa; transition: color 0.2s; }
                .header-actions span:hover { color: white; }
                .content { padding: 15px; display: block; }
                .status { font-size: 12px; color: #bbb; margin-bottom: 12px; }
                .input-group { display: flex; gap: 8px; margin-bottom: 15px; }
                .input-group input {
                    flex: 1; background: rgba(0,0,0,0.4); border: 1px solid #444;
                    border-radius: 6px; color: white; padding: 8px 12px; font-size: 13px;
                    outline: none; transition: border-color 0.2s;
                }
                .input-group input:focus { border-color: #4CAF50; }
                .input-group button {
                    background: #4CAF50; color: white; border: none; border-radius: 6px;
                    padding: 0 16px; font-weight: 600; cursor: pointer; font-size: 13px;
                    transition: background 0.2s;
                }
                .input-group button:active { background: #45a049; }
                .answer-area {
                    max-height: 40vh; overflow-y: auto; font-size: 13px; line-height: 1.6;
                    color: #eee; padding-right: 5px;
                }
                .answer-area::-webkit-scrollbar { width: 4px; }
                .answer-area::-webkit-scrollbar-thumb { background: #666; border-radius: 2px; }
            </style>
            <div class="dashboard" id="dashboard">
                <div class="header" id="drag-handle">
                    <div class="header-title">🤖 AI 外挂控制台</div>
                    <div class="header-actions">
                        <span id="min-btn">最小化 _</span>
                    </div>
                </div>
                <div class="content" id="main-content">
                    <div class="status" id="status-text">状态: 正在等待拦截试卷数据...</div>
                    <div class="input-group">
                        <input type="text" id="range-input" placeholder="范围如 1-10, 留空全做">
                        <button id="upload-btn">上传获取</button>
                    </div>
                    <div class="answer-area" id="answer-area">等待操作...</div>
                </div>
            </div>
        \`;

        document.body.appendChild(host);

        const handle = shadow.getElementById('drag-handle');
        const minBtn = shadow.getElementById('min-btn');
        const content = shadow.getElementById('main-content');
        const statusText = shadow.getElementById('status-text');
        const rangeInput = shadow.getElementById('range-input');
        const uploadBtn = shadow.getElementById('upload-btn');
        const answerArea = shadow.getElementById('answer-area');

        let isDragging = false, startY = 0, startTop = 0, startX = 0, startLeft = 0;
        handle.addEventListener('touchstart', e => {
            isDragging = true;
            startY = e.touches[0].clientY;
            startX = e.touches[0].clientX;
            startTop = parseInt(window.getComputedStyle(host).top, 10) || 20;
            startLeft = parseInt(window.getComputedStyle(host).left, 10) || 10;
        });
        handle.addEventListener('touchmove', e => {
            if (!isDragging) return;
            host.style.top = (startTop + e.touches[0].clientY - startY) + 'px';
            host.style.left = (startLeft + e.touches[0].clientX - startX) + 'px';
            e.preventDefault();
        }, { passive: false });
        handle.addEventListener('touchend', () => isDragging = false);

        let isMin = false;
        minBtn.onclick = () => {
            isMin = !isMin;
            content.style.display = isMin ? 'none' : 'block';
            minBtn.innerText = isMin ? '展开 ⬜' : '最小化 _';
        };

        uploadBtn.onclick = () => {
            if (!window.__aiExamData) {
                statusText.innerText = '状态: 错误 - 未拦截到试卷数据！';
                statusText.style.color = '#ff4444';
                return;
            }
            statusText.innerText = '状态: 正在智能裁剪数据并发往 Flutter...';
            statusText.style.color = '#4CAF50';
            answerArea.innerHTML = '<span style="color:#aaa;">🚀 AI 正在深度思考中，请稍候...</span>';
            
            let rangeStr = rangeInput.value.trim();
            let indices = parseRange(rangeStr);
            let rawObj = JSON.parse(window.__aiExamData);
            
            let safeSlice = (obj, idx) => {
                let recurse = (o, i, depth) => {
                    if (depth > 15) return o;
                    if (Array.isArray(o)) {
                        if (o.length > 0 && typeof o[0] === 'object' && o[0] !== null && (o[0].options || o[0].problem_id || o[0].content)) {
                            let filtered = [];
                            for (let j=0; j<o.length; j++) {
                                if (i.length === 0 || i.includes(window.__aiGlobalIndex)) filtered.push(o[j]);
                                window.__aiGlobalIndex++;
                            }
                            return filtered;
                        }
                        return o.map(v => recurse(v, i, depth+1));
                    } else if (typeof o === 'object' && o !== null) {
                        let res = {};
                        for (let k in o) res[k] = recurse(o[k], i, depth+1);
                        return res;
                    }
                    return o;
                };
                window.__aiGlobalIndex = 1;
                return recurse(obj, idx, 0);
            };
            
            let slicedObj = safeSlice(rawObj, indices);
            let slicedJson = JSON.stringify(slicedObj);
            
            if (window.flutter_inappwebview && window.flutter_inappwebview.callHandler) {
                window.flutter_inappwebview.callHandler('YuketangManualUpload', slicedJson);
            }
        };

        window.updateAiStatus = function(msg) {
            statusText.innerText = '状态: ' + msg;
            statusText.style.color = '#2196F3';
        };

        window.doAutoAnswer = function(answerStr, mode) {
            statusText.innerText = '状态: ✅ 答案已就绪！';
            statusText.style.color = '#4CAF50';
            answerArea.innerHTML = answerStr.replace(/\\n/g, '<br>');
            if (mode === 'full') {
                 let optionLabels = document.querySelectorAll('.option-item, .el-radio, .el-checkbox'); 
                 optionLabels.forEach(label => {
                     if(label.innerText.includes(answerStr)) {
                         label.click(); label.style.border = "2px solid #4CAF50";
                     }
                 });
                 let submitBtn = document.querySelector('.submit-btn, .btn-submit');
                 if(submitBtn) setTimeout(() => submitBtn.click(), 1500);
            }
        };
        
        let dashInterface = { statusText };
        host._dashInterface = dashInterface;
        return dashInterface;
    }

    function handleIntercept(jsonStr) {
        window.__aiExamData = jsonStr;
        let dash = injectDashboard();
        if (dash) {
            dash.statusText.innerText = '状态: 🎯 拦截成功！请设置范围并上传';
            dash.statusText.style.color = '#4CAF50';
        }
        if (!window.__aiSnapshotBackedUp && window.flutter_inappwebview && window.flutter_inappwebview.callHandler) {
            window.flutter_inappwebview.callHandler('YuketangBackup', jsonStr);
            window.__aiSnapshotBackedUp = true;
        }
    }

    const originalFetch = window.fetch;
    window.fetch = async function(...args) {
        const response = await originalFetch.apply(this, args);
        const clone = response.clone(); 
        clone.json().then(data => {
            let jsonStr = JSON.stringify(data);
            if (jsonStr.includes('paper_count') && !jsonStr.includes('"options"')) return;
            if (jsonStr.includes('"options"') || jsonStr.includes('"problem_id"')) handleIntercept(jsonStr);
        }).catch(e => {});
        return response;
    };

    const originalXHR = window.XMLHttpRequest;
    function newXHR() {
        const xhr = new originalXHR();
        const originalOpen = xhr.open;
        xhr.open = function(method, url, ...args) {
            return originalOpen.apply(this, [method, url, ...args]);
        };
        xhr.addEventListener('load', function() {
            try {
                let jsonStr = xhr.responseText;
                if (jsonStr.includes('paper_count') && !jsonStr.includes('"options"')) return;
                if (jsonStr.includes('"options"') || jsonStr.includes('"problem_id"')) handleIntercept(jsonStr);
            } catch(e) {}
        });
        return xhr;
    }
    window.XMLHttpRequest = newXHR;
    
    if (document.readyState === 'complete' || document.readyState === 'interactive') {
        setTimeout(injectDashboard, 1000);
    } else {
        document.addEventListener('DOMContentLoaded', injectDashboard);
    }
})();`
