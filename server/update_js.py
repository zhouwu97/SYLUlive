import os
path = 'e:/AI/xynewui/server/cmd/main.go'
with open(path, 'r', encoding='utf-8') as f:
    content = f.read()

old_js = '''(function() {
    const originalFetch = window.fetch;
    window.fetch = async function(...args) {
        const response = await originalFetch.apply(this, args);
        
        // 克隆一份响应用于读取，避免消耗掉原始的数据流
        const clone = response.clone(); 
        
        // 假设雨课堂获取题目的接口路径包含 "get_student_presentation" 或 "problem"
        if (args[0] && typeof args[0] === 'string' && args[0].includes('problem')) {
            clone.json().then(data => {
                // 将拦截到的题目 JSON 转化为字符串，通过约定好的 Channel 传给 Flutter
                if (window.flutter_inappwebview && window.flutter_inappwebview.callHandler) {
                    window.flutter_inappwebview.callHandler('YuketangHelper', JSON.stringify(data));
                }
            }).catch(e => console.error("解析题目JSON失败", e));
        }
        return response;
    };
})();'''

new_js = '''(function() {
    const originalFetch = window.fetch;
    window.fetch = async function(...args) {
        const response = await originalFetch.apply(this, args);
        
        const clone = response.clone(); 
        
        if (args[0] && typeof args[0] === 'string' && args[0].includes('problem')) {
            clone.json().then(data => {
                if (window.flutter_inappwebview && window.flutter_inappwebview.callHandler) {
                    window.flutter_inappwebview.callHandler('YuketangHelper', JSON.stringify(data));
                }
            }).catch(e => console.error("解析题目JSON失败", e));
        }
        return response;
    };

    // 挂载到全局，供 Flutter 随时调用
    window.doAutoAnswer = function(answerStr, mode) {
        let optionLabels = document.querySelectorAll('.option-item'); 
        let submitBtn = document.querySelector('.submit-btn');

        // 步骤 1：无差别自动选中答案（半自动和全自动都要执行）
        optionLabels.forEach(label => {
            // 如果选项文本包含计算出的答案（例如包含 "A"）
            if(label.innerText.includes(answerStr)) {
                label.click(); // 模拟点击选中
                label.style.border = "2px solid #4CAF50"; // 给用户一个醒目的绿色高亮提示
            }
        });

        // 步骤 2：模式判断
        if (mode === 'full') {
            // 全自动模式：延时 1.5 秒后自动交卷（防检测，假装人类反应时间）
            setTimeout(() => {
                if(submitBtn) {
                    submitBtn.click();
                }
            }, 1500); 
        } else {
            // 半自动模式：仅在页面顶部弹个小提示，等待用户手动点提交
            let toast = document.createElement('div');
            toast.innerText = `💡 AI 推荐答案: ${answerStr} (请确认后手动提交)`;
            toast.style.cssText = "position:fixed; top:20px; left:50%; transform:translateX(-50%); background:rgba(0,0,0,0.7); color:white; padding:10px 20px; border-radius:20px; z-index:9999;";
            document.body.appendChild(toast);
            setTimeout(() => toast.remove(), 5000);
        }
    };
})();'''

if old_js in content:
    content = content.replace(old_js, new_js)
    with open(path, 'w', encoding='utf-8') as f:
        f.write(content)
    print("Success")
else:
    print("Old JS not found in main.go")
