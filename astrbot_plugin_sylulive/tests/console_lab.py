"""Loopback-only UI acceptance lab, synthetic users; never included in plugin ZIP."""
import copy
import tempfile
import importlib
import time
from pathlib import Path
from astrbot.core.config.astrbot_config import AstrBotConfig

import jwt
import uvicorn
from fastapi.responses import HTMLResponse, Response
from fastapi.staticfiles import StaticFiles
from astrbot.dashboard.services.auth_service import DASHBOARD_JWT_COOKIE_NAME
from astrbot_plugin_sylulive.permission_policy import document
from test_permission_console import console_fixture, native_app


def create_lab():
    plugin, _, _ = console_fixture()
    directory = tempfile.TemporaryDirectory(prefix="sylulive-permissions-lab-")
    baseline = {**document(plugin.config), **copy.deepcopy(plugin.config)}
    plugin.config = AstrBotConfig(str(Path(directory.name) / "plugin.json"), default_config=copy.deepcopy(baseline))
    app = native_app(plugin)
    app.state.lab_directory = directory

    @app.post("/lab/reset")
    async def reset():
        plugin.config.save_config(copy.deepcopy(baseline))
        return {"ok": True}

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
    uvicorn.run(create_lab(), host="127.0.0.1", port=6198, log_level="warning")
