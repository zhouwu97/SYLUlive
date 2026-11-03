"use strict";
(() => {
    const $ = id => document.getElementById(id);
    const bridge = window.AstrBotPluginPage || window.AstrBotPluginView;
    const clone = value => structuredClone(value);
    const stable = value => JSON.stringify(value, function (_, v) { return v && typeof v === "object" && !Array.isArray(v) ? Object.fromEntries(Object.keys(v).sort().map(k => [k, v[k]])) : v; });
    const node = (tag, text, cls) => { const e = document.createElement(tag); if (text !== undefined)
        e.textContent = text; if (cls)
        e.className = cls; return e; };
    let base = null, draft = null, revision = "", capabilities = [], busy = false, uncertain = false, loadEpoch = 0, previewEpoch = 0, editIndex = -1, confirmAction = null;
    const stateLabels = { denied: "规则拒绝", disabled: "功能关闭", scope_required: "缺少本人授权", public_allowed: "允许公开查询", server_check_required: "入口条件通过" };
    const names = { everyone: "所有发起人", admins: "AstrBot 管理员", specified_users: "指定用户" };
    function timed(promise) { let timer; return Promise.race([promise, new Promise((_, reject) => { timer = setTimeout(() => reject(Error("timeout")), 10000); })]).finally(() => clearTimeout(timer)); }
    async function api(method, path, body) { if (!bridge)
        throw Error("bridge unavailable"); const r = await timed(method === "GET" ? bridge.apiGet(path) : bridge.apiPost(path, body)); if (!r || r.error)
        throw Error("request failed"); return r; }
    function ids(text) { return [...new Set(text.split(/[\s,，]+/).filter(Boolean))]; }
    function normalize(policy) { const p = clone(policy); p.access_rules = p.access_rules.map(r => ({ name: "", enabled: true, user_ids: [], group_ids: [], ...r, __template_key: "access_rule" })); return p; }
    function dirty() { return !!draft && stable(draft) !== stable(base); }
    function error(text) { $("global-error").textContent = text; $("global-error").hidden = !text; }
    function invalidateCheck() { previewEpoch++; $("preview-submit").disabled = busy || !draft; $("result-list").replaceChildren(); $("preview-message").hidden = false; $("preview-message").textContent = "会话或规则已变化，请重新检查。"; }
    function updateState() {
        $("policy-editor").disabled = busy || !draft;
        $("reload").disabled = busy;
        $("save").disabled = busy || !dirty() || uncertain;
        $("discard").disabled = busy || !dirty();
        $("save-state").textContent = busy ? "正在处理…" : uncertain ? "保存状态待核对" : dirty() ? "有未保存修改" : draft ? "已保存" : "尚未读取";
        $("preview-submit").disabled = busy || !draft;
        $("check-mode").textContent = dirty() ? "检查当前未保存规则；检查不会使规则生效，也不执行业务。" : "检查已保存规则，不执行业务操作。";
    }
    function renderSettings() { document.querySelectorAll("[data-setting]").forEach(e => { const v = draft[e.dataset.setting]; if (e.type === "checkbox")
        e.checked = !!v;
    else
        e.value = Array.isArray(v) ? v.join("\n") : v; }); }
    function renderRules() {
        const query = $("search").value.trim().toLowerCase(), effect = $("effect-filter").value;
        const rows = draft.access_rules.map((r, i) => ({ r, i })).filter(({ r }) => (effect === "all" || r.effect === effect) && [r.name, ...(r.user_ids || []), ...(r.group_ids || [])].join(" ").toLowerCase().includes(query));
        $("rule-count").textContent = String(draft.access_rules.length);
        $("rules-body").replaceChildren();
        $("rule-table").hidden = !rows.length;
        $("rules-empty").hidden = !!rows.length;
        $("rules-empty").textContent = draft.access_rules.length ? "没有匹配的规则，请调整搜索或筛选。" : "尚无权限规则。可新增规则，或在“功能与范围”设置默认行为。";
        for (const { r, i } of rows) {
            const tr = node("tr");
            const title = node("td");
            title.append(node("p", r.name || `规则 ${i + 1}`, "rule-name"), node("div", (r.capabilities || []).map(k => capabilities.find(c => c.id === k)?.label || k).join("、"), "rule-functions"));
            const subject = node("td", names[r.subjects] || "未设置");
            subject.dataset.label = "适用对象";
            if (r.user_ids?.length)
                subject.append(node("div", r.user_ids.join("、"), "rule-functions"));
            const scope = node("td", (r.chat_types || []).map(t => t === "private" ? "私聊" : "群聊").join("、"));
            scope.dataset.label = "会话与群范围";
            scope.append(node("div", r.group_ids?.length ? r.group_ids.join("、") : "不额外限定群号", "rule-functions"));
            const effectCell = node("td");
            effectCell.dataset.label = "效果";
            effectCell.append(node("span", r.effect === "deny" ? "禁止" : "允许", "badge " + (r.effect === "deny" ? "bad" : "")));
            const enabled = node("td");
            enabled.dataset.label = "启用";
            const toggle = node("input");
            toggle.type = "checkbox";
            toggle.checked = r.enabled !== false;
            toggle.setAttribute("aria-label", `启用规则：${r.name || i + 1}`);
            toggle.addEventListener("change", () => { draft.access_rules[i].enabled = toggle.checked; invalidateCheck(); updateState(); });
            const target = node("label", undefined, "rule-toggle");
            target.append(toggle);
            enabled.append(target);
            const actions = node("td");
            actions.dataset.label = "操作";
            const controls = node("div", undefined, "row-actions");
            const edit = node("button", "编辑", "link");
            edit.type = "button";
            edit.setAttribute("aria-label", `编辑规则：${r.name || i + 1}`);
            edit.addEventListener("click", () => openRule(i));
            const remove = node("button", "删除", "link danger-link");
            remove.type = "button";
            remove.setAttribute("aria-label", `删除规则：${r.name || i + 1}`);
            remove.addEventListener("click", () => confirm("删除规则", `删除“${r.name || "这条规则"}”？保存更改后生效。`, () => { draft.access_rules.splice(i, 1); renderRules(); invalidateCheck(); updateState(); $("add-rule").focus(); }));
            controls.append(edit, remove);
            actions.append(controls);
            tr.append(title, subject, scope, effectCell, enabled, actions);
            $("rules-body").append(tr);
        }
    }
    function confirm(title, message, action) { confirmAction = action; $("confirm-title").textContent = title; $("confirm-message").textContent = message; $("confirm-dialog").showModal(); $("confirm-cancel").focus(); }
    $("confirm-cancel").addEventListener("click", () => { $("confirm-dialog").close(); confirmAction = null; });
    $("confirm-ok").addEventListener("click", () => { const action = confirmAction; confirmAction = null; $("confirm-dialog").close(); if (action)
        action(); });
    async function load() { const stamp = ++loadEpoch; busy = true; error(""); updateState(); try {
        if (!bridge)
            throw Error("bridge unavailable");
        await timed(bridge.ready());
        const r = await api("GET", "/permissions/policy");
        if (stamp !== loadEpoch)
            return;
        accept(r);
        if (!$("platform").value)
            $("platform").value = r.platform_id || "";
    }
    catch (_) {
        if (stamp === loadEpoch)
            error("权限配置读取失败。请检查后台登录与插件版本，再重新读取；未修改任何配置。");
    }
    finally {
        if (stamp === loadEpoch) {
            busy = false;
            updateState();
        }
    } }
    function accept(r) { if (!r.policy || !Array.isArray(r.policy.access_rules) || typeof r.revision !== "string")
        throw Error("invalid policy"); base = normalize(r.policy); draft = clone(base); revision = r.revision; capabilities = r.capabilities; uncertain = false; renderSettings(); renderRules(); invalidateCheck(); error(""); }
    function validateRule(r) { if (!r.name.trim())
        return "请填写规则名称。"; if (!r.chat_types.length)
        return "请至少选择一种会话。"; if (!r.capabilities.length)
        return "请至少选择一项功能。"; if (r.subjects === "specified_users" && !r.user_ids.length)
        return "指定用户规则需要填写 QQ。"; if ([...r.user_ids, ...r.group_ids].some(id => !/^[1-9][0-9]{4,14}$/.test(id)))
        return "请填写原始 QQ 或群号，每项 5 至 15 位数字。"; if (r.group_ids.length && !r.chat_types.includes("group"))
        return "填写群号时需要选择群聊。"; return ""; }
    function openRule(index) { editIndex = index; const r = index < 0 ? { name: "", enabled: true, effect: "allow", subjects: "everyone", user_ids: [], group_ids: [], chat_types: ["private", "group"], capabilities: [] } : draft.access_rules[index]; $("rule-title").textContent = index < 0 ? "新增规则" : "编辑规则"; $("rule-name").value = r.name || ""; $("rule-effect").value = r.effect || "allow"; $("rule-subjects").value = r.subjects || "everyone"; $("rule-users").value = (r.user_ids || []).join("\n"); $("rule-groups").value = (r.group_ids || []).join("\n"); $("chat-private").checked = (r.chat_types || []).includes("private"); $("chat-group").checked = (r.chat_types || []).includes("group"); $("rule-enabled").checked = r.enabled !== false; $("rule-error").hidden = true; $("rule-capabilities").replaceChildren(...capabilities.map(c => { const label = node("label", undefined, "check"), input = node("input"); input.type = "checkbox"; input.value = c.id; input.checked = (r.capabilities || []).includes(c.id); label.append(input, document.createTextNode(c.label)); return label; })); $("rule-dialog").showModal(); $("rule-name").focus(); }
    function closeRule() { $("rule-dialog").close(); }
    $("rule-close").addEventListener("click", closeRule);
    $("rule-cancel").addEventListener("click", closeRule);
    $("rule-form").addEventListener("submit", event => { event.preventDefault(); const r = { __template_key: "access_rule", name: $("rule-name").value.trim(), enabled: $("rule-enabled").checked, effect: $("rule-effect").value, subjects: $("rule-subjects").value, user_ids: ids($("rule-users").value), group_ids: ids($("rule-groups").value), chat_types: [$("chat-private").checked ? "private" : null, $("chat-group").checked ? "group" : null].filter(Boolean), capabilities: [...$("rule-capabilities").querySelectorAll("input:checked")].map(e => e.value) }; const message = validateRule(r); if (message) {
        $("rule-error").textContent = message;
        $("rule-error").hidden = false;
        return;
    } if (editIndex < 0) {
        if (draft.access_rules.length >= 128) {
            $("rule-error").textContent = "最多支持 128 条规则。";
            $("rule-error").hidden = false;
            return;
        }
        draft.access_rules.push(r);
    }
    else
        draft.access_rules[editIndex] = r; closeRule(); renderRules(); invalidateCheck(); updateState(); });
    $("add-rule").addEventListener("click", () => openRule(-1));
    $("search").addEventListener("input", renderRules);
    $("effect-filter").addEventListener("change", renderRules);
    document.querySelectorAll("[data-setting]").forEach(e => e.addEventListener(e.type === "checkbox" || e.tagName === "SELECT" ? "change" : "input", () => { draft[e.dataset.setting] = e.type === "checkbox" ? e.checked : e.dataset.setting === "public_read_group_ids" ? ids(e.value) : e.value; invalidateCheck(); updateState(); }));
    $("reload").addEventListener("click", () => { if (dirty())
        confirm("重新读取", "这会放弃当前未保存的修改，读取已保存配置。", load);
    else
        load(); });
    $("discard").addEventListener("click", () => { draft = clone(base); renderSettings(); renderRules(); invalidateCheck(); error(""); updateState(); });
    $("save").addEventListener("click", async () => { if (!dirty() || busy || uncertain)
        return; const invalid = draft.public_read_group_ids.some(id => !/^[1-9][0-9]{4,14}$/.test(id)) ? "请检查默认群号。" : draft.access_rules.map((r, i) => { const m = validateRule(r); return m ? `第 ${i + 1} 条规则：${m}` : ""; }).find(Boolean); if (invalid) {
        error(invalid);
        return;
    } const wanted = clone(draft), oldRevision = revision; busy = true; error(""); updateState(); try {
        accept(await api("POST", "/permissions/policy", { revision: oldRevision, policy: wanted }));
    }
    catch (_) {
        uncertain = true;
        try {
            const latest = await api("GET", "/permissions/policy");
            if (stable(normalize(latest.policy)) === stable(wanted)) {
                accept(latest);
            }
            else if (latest.revision !== oldRevision) {
                error("配置已在其他位置修改。你的修改仍保留，请重新读取后再编辑，避免覆盖他人更改。");
            }
            else {
                error("保存结果未确认，修改仍保留。请重新读取核对后再操作；不会自动重试保存。");
            }
        }
        catch (_) {
            error("保存结果未确认。请恢复连接后重新读取核对；不会自动重试保存。");
        }
    }
    finally {
        busy = false;
        updateState();
    } });
    document.querySelectorAll("[data-view]").forEach(button => button.addEventListener("click", () => { document.querySelectorAll("[data-view]").forEach(b => b.setAttribute("aria-pressed", String(b === button))); for (const view of ["rules", "settings", "check"])
        $(view + "-panel").hidden = view !== button.dataset.view; }));
    $("preview-form").addEventListener("input", invalidateCheck);
    $("preview-form").addEventListener("submit", async (event) => { event.preventDefault(); const stamp = ++previewEpoch; $("preview-submit").disabled = true; $("preview-message").hidden = false; $("preview-message").textContent = "正在检查…"; $("result-list").replaceChildren(); const target = { platform_id: $("platform").value.trim(), bot_id: $("bot").value.trim(), sender_id: $("sender").value.trim(), group_id: $("group").value.trim(), member_isolated: $("isolated").checked }; try {
        const result = await api("POST", "/permissions/preview", dirty() ? { target, policy: draft } : target);
        if (stamp !== previewEpoch)
            return;
        $("preview-message").hidden = true;
        $("result-list").replaceChildren(...result.items.map(item => { const row = node("article", undefined, "result-row"), head = node("div", undefined, "section-head"), checks = node("div", undefined, "checks"); head.append(node("h3", item.title), node("span", stateLabels[item.state] || "待核验", "badge " + (item.state === "denied" || item.state === "disabled" ? "bad" : item.state === "public_allowed" ? "" : "wait"))); checks.append(node("span", "规则：" + (item.rule.allowed ? "允许" : "拒绝") + (item.rule.name ? " · " + item.rule.name : "")), node("span", "功能：" + (item.feature_enabled ? "开启" : "关闭")), node("span", item.required_scope ? (item.local_scope_present ? "本机有该授权" : "本机缺少该项授权") : "无需额外数据授权"), node("span", "服务端仍会复核")); row.append(head, node("p", item.reason), checks); return row; }));
    }
    catch (_) {
        if (stamp === previewEpoch) {
            $("preview-message").textContent = "权限检查未完成。请核对输入和后台登录后重试。";
            $("preview-message").hidden = false;
        }
    }
    finally {
        if (stamp === previewEpoch)
            $("preview-submit").disabled = false;
    } });
    if (bridge?.onContext)
        bridge.onContext(context => document.documentElement.setAttribute("data-theme", context.isDark ? "dark" : "light"));
    window.addEventListener("beforeunload", event => { if (dirty()) {
        event.preventDefault();
        event.returnValue = "";
    } });
    load();
})();
