import { useEffect, useId, useRef, useState, type CSSProperties } from "react";
import { Icon } from "./ui";

// 桌面网页外观：主题色与页面顶部的淡色渐变。来自校园投票「淡色分区渐变（可以自选颜色）」（96% 支持）。
// 只写 :root 上的 data-* 与 --user-accent，真正生效的样式限定在 601px 以上，手机网页仍对照 App。
export type Wash = "section" | "accent" | "plain";
type Appearance = { accent: string; wash: Wash };

const STORAGE_KEY = "sylulive-appearance";
export const DEFAULT_ACCENT = "#3d63f0";
export const ACCENTS: [string, string][] = [
  ["#3d63f0", "沈理蓝"],
  ["#0d7f74", "松石青"],
  ["#2b7d48", "校园绿"],
  ["#c2491a", "枫叶橙"],
  ["#c93a6c", "樱花粉"],
  ["#6d4fd8", "丁香紫"],
  ["#2b2f38", "墨色"],
];
const WASHES: [Wash, string][] = [["section", "分区渐变"], ["accent", "主题色渐变"], ["plain", "纯色"]];
const HEX = /^#[0-9a-f]{6}$/i;

export function readAppearance(): Appearance {
  try {
    const saved = JSON.parse(localStorage.getItem(STORAGE_KEY) || "{}") as Partial<Appearance>;
    return {
      accent: typeof saved.accent === "string" && HEX.test(saved.accent) ? saved.accent.toLowerCase() : DEFAULT_ACCENT,
      wash: WASHES.some(([value]) => value === saved.wash) ? saved.wash as Wash : "section",
    };
  } catch {
    return { accent: DEFAULT_ACCENT, wash: "section" };
  }
}

export function applyAppearance({ accent, wash }: Appearance) {
  const root = document.documentElement;
  if (accent === DEFAULT_ACCENT) {
    delete root.dataset.accent;
    root.style.removeProperty("--user-accent");
  } else {
    root.dataset.accent = "custom";
    root.style.setProperty("--user-accent", accent);
  }
  root.dataset.wash = wash;
}

export function AppearanceButton() {
  const [value, setValue] = useState(readAppearance);
  const [open, setOpen] = useState(false);
  const panelId = useId();
  const wrap = useRef<HTMLDivElement>(null);
  const button = useRef<HTMLButtonElement>(null);

  useEffect(() => {
    applyAppearance(value);
    try { localStorage.setItem(STORAGE_KEY, JSON.stringify(value)); } catch { /* 隐私模式下只在本次会话生效 */ }
  }, [value]);

  useEffect(() => {
    if (!open) return;
    const outside = (event: PointerEvent) => { if (!wrap.current?.contains(event.target as Node)) setOpen(false); };
    const key = (event: KeyboardEvent) => {
      if (event.key !== "Escape") return;
      setOpen(false);
      button.current?.focus();
    };
    document.addEventListener("pointerdown", outside);
    document.addEventListener("keydown", key);
    wrap.current?.querySelector<HTMLElement>("[aria-pressed='true']")?.focus();
    return () => {
      document.removeEventListener("pointerdown", outside);
      document.removeEventListener("keydown", key);
    };
  }, [open]);

  const custom = !ACCENTS.some(([color]) => color === value.accent);
  return (
    <div className="appearance" ref={wrap}>
      <button
        ref={button}
        className="icon-btn"
        aria-label="外观设置"
        aria-haspopup="dialog"
        aria-expanded={open}
        aria-controls={panelId}
        onClick={() => setOpen(!open)}
      >
        <Icon name="palette" />
      </button>
      {open && (
        <div className="appearance-panel" id={panelId} role="dialog" aria-label="外观设置">
          <div className="appearance-head">
            <b>外观设置</b>
            <button className="icon-btn" aria-label="关闭外观设置" onClick={() => { setOpen(false); button.current?.focus(); }}><Icon name="close" size={16} /></button>
          </div>
          <p className="appearance-label">主题色</p>
          <div className="appearance-swatches" role="group" aria-label="主题色">
            {ACCENTS.map(([color, name]) => (
              <button
                key={color}
                className="appearance-swatch"
                style={{ "--swatch": color } as CSSProperties}
                aria-label={name}
                title={name}
                aria-pressed={value.accent === color}
                onClick={() => setValue({ ...value, accent: color })}
              />
            ))}
            <label className={`appearance-swatch appearance-custom ${custom ? "is-custom" : ""}`} title="自定义颜色" style={custom ? { "--swatch": value.accent } as CSSProperties : undefined}>
              <input type="color" aria-label="自定义主题色" value={value.accent} onChange={(event) => setValue({ ...value, accent: event.target.value.toLowerCase() })} />
            </label>
          </div>
          <p className="appearance-label">背景</p>
          <div className="appearance-washes" role="group" aria-label="背景">
            {WASHES.map(([wash, name]) => (
              <button key={wash} aria-pressed={value.wash === wash} onClick={() => setValue({ ...value, wash })}>{name}</button>
            ))}
          </div>
          <p className="appearance-hint">分区渐变：首页跟随主题色，食堂、集市、学习、校园各有一种淡色，一眼认出当前在哪。</p>
        </div>
      )}
    </div>
  );
}
