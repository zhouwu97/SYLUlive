import { useState } from "react";

const pluginPath = "/#/plugin-view/astrbot_plugin_sylulive/permissions";

export function AstrBotDashboard() {
  const [address, setAddress] = useState("http://127.0.0.1:6185");
  let href = "";
  try {
    const url = new URL(address.trim());
    if (["http:", "https:"].includes(url.protocol) && !url.username && !url.password &&
        url.pathname === "/" && !url.search && !url.hash) href = url.origin + pluginPath;
  } catch { /* 编辑地址时允许暂时不完整，不生成无效链接。 */ }
  return <section className="panel panel-pad integration-panel astrbot-dashboard" aria-label="AstrBot 插件后台">
    <h2>AstrBot 插件后台</h2>
    <p>管理用户与群规则、功能开关及权限检查。点击后在新标签页打开 SYLUlive 插件的「权限管理」，未登录时先登录 AstrBot。</p>
    {href ? <a className="btn" href={href} target="_blank" rel="noopener noreferrer">打开 AstrBot 插件管理</a>
      : <p role="alert">请填写完整的 http:// 或 https:// 后台地址，仅保留域名和端口，不含密码、路径或参数。</p>}
    <p className="integration-hint">默认打开这台电脑上的 AstrBot（127.0.0.1:6185）。使用别人的机器人时，后台由部署者管理；本人评论、发帖授权仍在下方「核对连接请求」确认。</p>
    <details className="connection-permission-details">
      <summary>修改后台地址／打不开？</summary>
      <label className="field">AstrBot 后台地址<input type="url" value={address} onChange={event => setAddress(event.target.value)} placeholder="http://127.0.0.1:6185" autoComplete="off" spellCheck={false} /></label>
      <p className="integration-hint">AstrBot 在其他电脑、服务器或端口运行时，填写部署者提供的后台地址。连接被拒绝时，检查服务是否启动及地址是否正确；旧版没有插件视图时，从 AstrBot「插件」进入 SYLUlive。本站登录不会代替 AstrBot 后台登录。</p>
    </details>
  </section>;
}
