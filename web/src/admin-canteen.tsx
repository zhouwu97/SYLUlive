import { useState, type FormEvent } from "react";
import { useQueryClient } from "@tanstack/react-query";
import { asset, errorText, query, rows, time, upload, useApi, write, type Entity } from "./api";
import { useAuth } from "./auth";
import { formatScore } from "./canteen/canteen-data";
import { waitLevel, waitText } from "./admin-time";
import { Empty, Form, Head, Icon, Pagination, QueryState, useUI } from "./ui";

const AREAS: [string, string][] = [["", "全部区域"], ["一食堂", "一食堂"], ["二食堂", "二食堂"]];
const FLOORS: [string, string][] = [["", "未设置"], ["一楼", "一楼"], ["二楼", "二楼"], ["三楼", "三楼"]];

export function AdminCanteenModule() {
  const auth = useAuth(), ui = useUI(), qc = useQueryClient();
  const isSuper = auth.user?.role === "super_admin";
  const [view, setView] = useState<"pending" | "stores">("pending");
  const [qText, setQText] = useState("");
  const [area, setArea] = useState("");
  const [status, setStatus] = useState("all");
  const [page, setPage] = useState(1);

  const pending = useApi("/api/canteens/pending");
  const stores = useApi(
    view === "stores"
      ? query("/api/canteens/admin-list", { q: qText, location_area: area, operating_status: status, page, limit: 20 })
      : null,
  );
  const pendingList = rows(pending.data, "canteens", "items");
  const storeList = rows(stores.data, "canteens", "items");
  const invalidate = () => qc.invalidateQueries({ predicate: (q) => q.queryKey[0] === "api" && String(q.queryKey[1]).startsWith("/api/canteens") });

  return (
    <>
      <Head level={2} title="食堂审核与商户运营" description="审核同学提交的新档口，维护在营与怀旧商户资料、展示标签、菜品及实拍。">
        <div className="admin-seg" role="group" aria-label="食堂管理视图">
          <button type="button" aria-pressed={view === "pending"} onClick={() => setView("pending")}>
            待审提交{!pending.isPending && !pending.error ? ` (${pendingList.length})` : ""}
          </button>
          <button type="button" aria-pressed={view === "stores"} onClick={() => setView("stores")}>
            全部商户与菜品
          </button>
        </div>
        <button className="btn" disabled={pending.isFetching || stores.isFetching} onClick={() => { void pending.refetch(); if (view === "stores") void stores.refetch(); }}>
          刷新
        </button>
      </Head>

      {view === "pending" ? (
        <QueryState query={pending}>
          {pendingList.length > 0 ? (
            <div className="admin-reports">
              {pendingList.map((item) => (
                <PendingCanteenCard key={item.id} item={item} onDone={() => void invalidate()} />
              ))}
            </div>
          ) : (
            <div className="panel">
              <Empty icon="check" title="当前队列为空" description="暂无待审核的食堂档口提交，可前往全部商户维护在营档口、展示标签与菜品。">
                <button type="button" className="btn primary" onClick={() => setView("stores")}>进入全部商户管理</button>
              </Empty>
            </div>
          )}
        </QueryState>
      ) : (
        <>
          <div className="filter-row admin-toolbar">
            <form
              className="admin-search"
              onSubmit={(e) => {
                e.preventDefault();
                setPage(1);
                setQText(String(new FormData(e.currentTarget).get("q") || "").trim());
              }}
            >
              <input name="q" aria-label="搜索商户" defaultValue={qText} placeholder="搜索档口名称、窗口或简介" />
              <button className="btn">搜索</button>
            </form>
            <div className="admin-inline-filters">
              <select aria-label="食堂区域" value={area} onChange={(e) => { setArea(e.target.value); setPage(1); }}>
                {AREAS.map(([v, l]) => <option key={v} value={v}>{l}</option>)}
              </select>
              <select aria-label="营业状态" value={status} onChange={(e) => { setStatus(e.target.value); setPage(1); }}>
                <option value="all">全部状态</option>
                <option value="open">营业中</option>
                <option value="offline">怀旧已下架</option>
              </select>
            </div>
          </div>

          <QueryState query={stores}>
            <div className="panel admin-list">
              {storeList.map((c) => {
                const offline = Boolean(c.is_offline || c.operating_status === "offline");
                const canWrite = !offline || isSuper;
                const loc = [c.location_area, c.location_floor, c.windows].filter(Boolean).join(" · ");
                const img = asset(c.image || c.image_url);
                return (
                  <div className="list-row admin-row admin-store-row" key={c.id}>
                    <span className="admin-store-thumb">
                      {img ? <img src={img} alt="" loading="lazy" /> : <Icon name="canteen" size={20} />}
                    </span>
                    <div className="list-main">
                      <div className="admin-row-head">
                        <b>{c.name}</b>
                        <span className={`tag ${offline ? "" : "is-resolved"}`}>{offline ? "怀旧下架" : "营业中"}</span>
                        {Number(c.rating_count) > 0 && <span className="tag brand">★ {formatScore(c.average_star)} · {c.rating_count} 评</span>}
                      </div>
                      <p>{loc || "未设置位置"}{c.opening_hours ? ` · 营业时间 ${c.opening_hours}` : ""}</p>
                      {c.description && <small>{c.description}</small>}
                    </div>
                    <div className="admin-row-actions">
                      <button
                        type="button"
                        className="btn sm"
                        onClick={() => ui.open(`菜品与实拍 · ${c.name}`, <CanteenDishesDrawer canteen={c} canWrite={canWrite} onSaved={() => void invalidate()} />, "drawer")}
                      >
                        菜品管理
                      </button>
                      {canWrite ? (
                        <>
                          <button
                            type="button"
                            className="btn sm"
                            onClick={() => ui.open(`编辑商户 · ${c.name}`, <CanteenEditDrawer item={c} onSaved={() => void invalidate()} />, "drawer")}
                          >
                            编辑资料
                          </button>
                          {!offline ? (
                            <button
                              type="button"
                              className="btn sm"
                              onClick={() => ui.open(`下架归档 · ${c.name}`, (
                                <Form
                                  fields={[{ name: "reason", label: "下架说明（选填）", type: "textarea" }]}
                                  submit="确认下架至怀旧食堂"
                                  onSubmit={async (values) => {
                                    await write(`/api/canteens/${c.id}/offline`, values);
                                    await invalidate();
                                    ui.notify("已下架至怀旧食堂");
                                    ui.close();
                                  }}
                                />
                              ))}
                            >
                              下架
                            </button>
                          ) : (
                            <button
                              type="button"
                              className="btn sm primary"
                              onClick={() => void ui.act(async () => { await write(`/api/canteens/${c.id}/online`); await invalidate(); }, "商户已恢复营业")}
                            >
                              恢复营业
                            </button>
                          )}
                          <button
                            type="button"
                            className="btn sm danger"
                            onClick={() => ui.open("删除商户", (
                              <>
                                <p>删除「{c.name}」后不可恢复；如仅档口撤柜，请优先使用“下架”保留同学历史评价。</p>
                                <div className="form-actions">
                                  <button type="button" className="btn danger" onClick={async () => {
                                    if (await ui.act(async () => { await write(`/api/canteens/${c.id}`, {}, "DELETE"); await invalidate(); }, "商户已删除")) ui.close();
                                  }}>确认永久删除</button>
                                </div>
                              </>
                            ))}
                          >
                            删除
                          </button>
                        </>
                      ) : (
                        <span className="muted">怀旧资料仅超管可改</span>
                      )}
                    </div>
                  </div>
                );
              })}
              {!storeList.length && <Empty title="没有匹配的食堂商户" />}
            </div>
            {(page > 1 || storeList.length === 20) && (
              <Pagination page={page} hasMore={storeList.length === 20} onChange={setPage} />
            )}
          </QueryState>
        </>
      )}
    </>
  );
}

function PendingCanteenCard({ item, onDone }: { item: Entity; onDone: () => void }) {
  const ui = useUI();
  const [rejecting, setRejecting] = useState(false);
  const [reason, setReason] = useState("");
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState("");
  const img = asset(item.image || item.image_url);
  const loc = [item.location_area, item.location_floor, item.windows].filter(Boolean).join(" · ");
  const level = waitLevel(item.created_at);

  async function decide(approve: boolean, e?: FormEvent) {
    e?.preventDefault();
    if (busy) return;
    setBusy(true);
    setErr("");
    try {
      if (approve) await write(`/api/canteens/${item.id}/approve`);
      else await write(`/api/canteens/${item.id}/pending`, { reason: reason.trim() }, "DELETE");
      onDone();
      ui.notify(approve ? `已通过「${item.name}」` : `已驳回「${item.name}」`);
    } catch (error) {
      setErr(errorText(error));
    } finally {
      setBusy(false);
    }
  }

  return (
    <article className="panel admin-report">
      <div className="admin-report-title">
        <span className="tag warn">新档口申请</span>
        <b>{item.name || `商户 #${item.id}`}</b>
        {loc && <span className="admin-report-id">{loc}</span>}
        <span className="admin-report-status">
          {waitText(item.created_at) && <em className={`admin-wait ${level}`}>等待 {waitText(item.created_at)}</em>}
        </span>
      </div>
      <div className="admin-canteen-pending-body">
        {img && <a className="admin-canteen-pending-img" href={img} target="_blank" rel="noreferrer"><img src={img} alt={`${item.name}封面`} loading="lazy" /></a>}
        <div className="admin-canteen-pending-copy">
          {item.description ? <p>{item.description}</p> : <p className="muted">提交人未填写档口简介</p>}
          {item.opening_hours && <small>营业时间：{item.opening_hours}</small>}
          <small>提交人：{item.submitter?.nickname || item.user?.nickname || (item.created_by ? `UID ${item.created_by}` : "校园同学")} · {time(item.created_at)}</small>
        </div>
      </div>
      {err && <p className="field-error" role="alert">{err}</p>}
      {rejecting ? (
        <form className="admin-decide" onSubmit={(e) => void decide(false, e)}>
          <label className="field">驳回说明（告知提交同学）
            <textarea rows={2} required value={reason} disabled={busy} onChange={(e) => setReason(e.target.value)} placeholder="例如：档口名称或楼层位置不准确，请补充门头实拍" />
          </label>
          <div className="admin-decide-foot">
            <button type="button" className="btn" disabled={busy} onClick={() => setRejecting(false)}>取消</button>
            <button className="btn danger" disabled={busy}>{busy ? "正在提交…" : "确认驳回"}</button>
          </div>
        </form>
      ) : (
        <div className="admin-report-foot">
          <small className="admin-report-meta">ID #{item.id}</small>
          <span className="admin-report-actions">
            <button type="button" className="btn" disabled={busy} onClick={() => setRejecting(true)}>驳回…</button>
            <button type="button" className="btn primary" disabled={busy} onClick={() => void decide(true)}>{busy ? "正在处理…" : "通过上架"}</button>
          </span>
        </div>
      )}
    </article>
  );
}

function CanteenEditDrawer({ item, onSaved }: { item: Entity; onSaved: () => void }) {
  const ui = useUI();
  const tagsQuery = useApi(`/api/canteens/${item.id}/display-tags`);
  const tagData = tagsQuery.data || {};
  const initialMode = String(tagData.mode || "auto");
  const [tagMode, setTagMode] = useState<string>("");
  const activeMode = tagMode || initialMode;

  return (
    <div className="admin-drawer-stack">
      <Form
        key={`${item.id}:${initialMode}`}
        fields={[
          { name: "name", label: "商户名称", value: item.name, required: true },
          { name: "location_area", label: "食堂区域", value: item.location_area || "", options: [["", "未设置"], ["一食堂", "一食堂"], ["二食堂", "二食堂"]] },
          { name: "location_floor", label: "所在楼层", value: item.location_floor || "", options: FLOORS },
          { name: "windows", label: "窗口号 / 具体位置", value: item.windows || "" },
          { name: "opening_hours", label: "营业时间", value: item.opening_hours || "" },
          { name: "description", label: "商户简介", type: "textarea", value: item.description || "" },
          { name: "cover", label: "更换门头封面（可选）", type: "file", accept: "image/*" },
        ]}
        onSubmit={async (values, fd) => {
          const cover = fd.get("cover");
          if (cover instanceof File && cover.size > 0) {
            const image_url = await upload(cover);
            await write(`/api/canteens/${item.id}/image`, { image_url }, "PUT");
          }
          const manualRaw = String(fd.get("manual_tags") || "");
          const manualList = manualRaw.split(/[,，、\s]+/).map((s) => s.trim()).filter(Boolean).slice(0, 3);
          const tagsPayload = activeMode === "auto" ? null : activeMode === "hidden" ? [] : manualList;
          await write(`/api/canteens/${item.id}`, {
            name: values.name,
            location_area: values.location_area,
            location_floor: values.location_floor,
            windows: values.windows,
            opening_hours: values.opening_hours,
            description: values.description,
          }, "PATCH");
          await write(`/api/canteens/${item.id}/display-tags`, { tags: tagsPayload }, "PUT");
          onSaved();
          ui.notify("商户资料与标签已保存");
          ui.close();
        }}
      >
        <fieldset className="admin-fieldset">
          <legend>展示标签策略</legend>
          <label className="field">标签来源
            <select value={activeMode} onChange={(e) => setTagMode(e.target.value)}>
              <option value="auto">自动提取同学评价热词</option>
              <option value="manual">手动指定标签（最多 3 个）</option>
              <option value="hidden">隐藏所有标签</option>
            </select>
          </label>
          {activeMode === "manual" && (
            <label className="field">自定义标签（用逗号分隔，最多 3 个）
              <input name="manual_tags" defaultValue={Array.isArray(tagData.manual_tags) ? tagData.manual_tags.join("，") : ""} placeholder="例如：出餐快，分量足，少油" />
            </label>
          )}
          {Array.isArray(tagData.effective_tags) && tagData.effective_tags.length > 0 && (
            <small className="muted">当前生效：{tagData.effective_tags.join(" · ")}</small>
          )}
        </fieldset>
      </Form>
    </div>
  );
}

function CanteenDishesDrawer({ canteen, canWrite, onSaved }: { canteen: Entity; canWrite: boolean; onSaved: () => void }) {
  const ui = useUI();
  const q = useApi(`/api/canteens/${canteen.id}/admin-dishes`);
  const dishes = rows(q.data, "items", "dishes");
  const [mergeSource, setMergeSource] = useState<number | null>(null);
  const [mergeTarget, setMergeTarget] = useState<string>("");

  return (
    <QueryState query={q}>
      <div className="admin-drawer-stack">
        <p className="muted">共 {dishes.length} 道菜品。{canWrite ? "支持改名、隐藏重复项、合并同菜不同名及管理菜品实拍。" : "怀旧下架商户菜品仅超级管理员可修改。"}</p>
        {dishes.map((dish) => {
          const hidden = dish.status === "hidden";
          const photos = rows(dish, "photos");
          return (
            <div className="panel panel-pad admin-dish-card" key={dish.id}>
              <div className="admin-row-head">
                <b>{dish.name}</b>
                <span className={`tag ${hidden ? "" : "is-resolved"}`}>{hidden ? "已隐藏" : "展示中"}</span>
                {Number(dish.average_score) > 0 && <span className="tag brand">★ {formatScore(dish.average_score)}</span>}
                <small className="muted">ID #{dish.id}</small>
              </div>
              {canWrite && (
                <div className="admin-inline-actions">
                  <button
                    type="button"
                    className="btn sm"
                    onClick={() => ui.open(`修改菜名 · ${dish.name}`, (
                      <Form
                        fields={[{ name: "name", label: "菜品名称", value: dish.name, required: true }]}
                        onSubmit={async (v) => {
                          await write(`/api/canteens/dishes/${dish.id}`, { name: v.name }, "PATCH");
                          await q.refetch();
                          onSaved();
                          ui.notify("菜名已更新");
                          ui.close();
                        }}
                      />
                    ))}
                  >
                    改名
                  </button>
                  <button
                    type="button"
                    className="btn sm"
                    onClick={() => void ui.act(async () => {
                      await write(`/api/canteens/dishes/${dish.id}`, { status: hidden ? "active" : "hidden" }, "PATCH");
                      await q.refetch();
                      onSaved();
                    }, hidden ? "菜品已恢复展示" : "菜品已隐藏")}
                  >
                    {hidden ? "恢复展示" : "隐藏"}
                  </button>
                  {dishes.length > 1 && (
                    <button type="button" className="btn sm" onClick={() => { setMergeSource(mergeSource === dish.id ? null : Number(dish.id)); setMergeTarget(""); }}>
                      合并到其他菜品
                    </button>
                  )}
                </div>
              )}
              {canWrite && mergeSource === Number(dish.id) && (
                <div className="admin-merge-bar">
                  <select aria-label="合并目标菜品" value={mergeTarget} onChange={(e) => setMergeTarget(e.target.value)}>
                    <option value="">选择保留的目标菜品…</option>
                    {dishes.filter((d) => d.id !== dish.id).map((d) => <option key={d.id} value={d.id}>{d.name} (#{d.id})</option>)}
                  </select>
                  <button
                    type="button"
                    className="btn sm primary"
                    disabled={!mergeTarget}
                    onClick={() => void ui.act(async () => {
                      await write(`/api/canteens/dishes/${dish.id}/merge`, { target_dish_id: Number(mergeTarget) });
                      setMergeSource(null);
                      await q.refetch();
                      onSaved();
                    }, "菜品已合并")}
                  >
                    确认合并
                  </button>
                </div>
              )}
              {photos.length > 0 && (
                <div className="admin-photo-strip">
                  {photos.map((p) => {
                    const url = asset(p.image || p.url);
                    return (
                      <div className="admin-photo-item" key={p.id}>
                        {url && <a href={url} target="_blank" rel="noreferrer"><img src={url} alt="" loading="lazy" /></a>}
                        {canWrite && (
                          <div className="admin-photo-btns">
                            <button type="button" className="link-btn" onClick={() => void ui.act(async () => { await write(`/api/canteens/dish-photos/${p.id}/cover`); await q.refetch(); onSaved(); }, "已设为菜品封面")}>设封面</button>
                            <button type="button" className="link-btn" onClick={() => void ui.act(async () => { await write(`/api/canteens/dish-photos/${p.id}/archive`, { reason: "管理端归档" }); await q.refetch(); onSaved(); }, "实拍已归档")}>归档</button>
                          </div>
                        )}
                      </div>
                    );
                  })}
                </div>
              )}
            </div>
          );
        })}
        {!dishes.length && <Empty title="该商户暂无菜品记录" />}
      </div>
    </QueryState>
  );
}
