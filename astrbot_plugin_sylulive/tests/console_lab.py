"""Loopback-only UI acceptance lab, synthetic users; never included in plugin ZIP."""
import importlib
import time
from pathlib import Path
from types import SimpleNamespace

import jwt
import uvicorn
from fastapi.responses import HTMLResponse, Response
from fastapi.staticfiles import StaticFiles
from astrbot.dashboard.services.auth_service import DASHBOARD_JWT_COOKIE_NAME
from test_permission_console import console_fixture, native_app


def create_lab():
    plugin, _, _ = console_fixture()
    plugin.config.update(community_auto_browse=True, community_auto_comment=True,
                         community_memory_mode="lexical")
    plugin.public_agent = SimpleNamespace(state="completed", clock=time.monotonic,
        next_run=time.monotonic()+1800, publisher=SimpleNamespace(authorized=lambda: False),
        last_result={"at":time.time(),"state":"completed","read_count":3})
    app = native_app(plugin)
    package = Path(importlib.import_module("astrbot_plugin_sylulive.permission_console").__file__).parent
    page = package / "pages/permissions"
    app.mount("/assets", StaticFiles(directory=page))

    @app.get("/")
    async def index():
        html=(page/"index.html").read_text(encoding="utf-8").replace("./app.css","/assets/app.css").replace("./app.js","/assets/app.js")
        html=html.replace('<script src="/assets/app.js" defer>', '<script src="/lab/bridge.js"></script><script src="/assets/app.js" defer>')
        html=html.replace('<main>', '<main><p class="notice">隔离验收环境 · 全部账号与授权均为合成夹具，不连接 QQ 或校园服务。</p>')
        response=HTMLResponse(html,headers={"Cache-Control":"no-store"})
        token=jwt.encode({"username":"synthetic-admin","exp":time.time()+1800},app.state.jwt_secret,algorithm="HS256")
        response.set_cookie(DASHBOARD_JWT_COOKIE_NAME,token,httponly=True,samesite="strict")
        return response

    @app.get("/lab/bridge.js")
    async def bridge():
        return Response('''window.AstrBotPluginPage={ready:()=>Promise.resolve(),onContext:f=>f({isDark:false}),
          apiGet:async p=>{const r=await fetch('/api/plug/astrbot_plugin_sylulive'+p,{credentials:'same-origin'});if(!r.ok)throw Error('failed');return r.json();},
          apiPost:async(p,b)=>{const r=await fetch('/api/plug/astrbot_plugin_sylulive'+p,{method:'POST',headers:{'Content-Type':'application/json'},credentials:'same-origin',body:JSON.stringify(b)});if(!r.ok)throw Error('failed');return r.json();}};''',media_type="application/javascript")
    return app


if __name__ == "__main__":
    uvicorn.run(create_lab(), host="127.0.0.1", port=6197, log_level="warning")
