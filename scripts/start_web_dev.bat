@echo off
chcp 65001 >nul
setlocal enabledelayedexpansion

rem ============================================================
rem  Flutter Web 本地开发一键启动
rem
rem  启动两个进程：
rem    1) Flutter dev server  —— 提供前端静态资源与热重载
rem    2) Node 开发代理       —— 把 /api 反代到后端，保证同源
rem
rem  然后自动打开浏览器访问代理入口。
rem  两个窗口都会保留，可分别查看日志；直接关掉即可停止。
rem ============================================================

rem 项目根目录（scripts 的上一级）
set "PROJECT_ROOT=%~dp0.."
pushd "%PROJECT_ROOT%"
set "PROJECT_ROOT=%CD%"

set "FLUTTER_PORT=8082"
set "PROXY_PORT=3000"
set "API_TARGET=https://sylulive.online"
set "FLUTTER_BAT=C:\KAIFA\tools\flutter\bin\flutter.bat"

echo.
echo  ══════════════════════════════════════════════════════
echo    Flutter Web 本地开发环境
echo  ══════════════════════════════════════════════════════
echo    项目目录    %PROJECT_ROOT%
echo    dev server  127.0.0.1:%FLUTTER_PORT%
echo    代理入口    http://127.0.0.1:%PROXY_PORT%
echo    后端地址    %API_TARGET%
echo  ══════════════════════════════════════════════════════
echo.

rem ---------- 前置检查：Flutter ----------
if not exist "%FLUTTER_BAT%" (
    echo  [错误] 未找到 Flutter：%FLUTTER_BAT%
    echo         请修改脚本中的 FLUTTER_BAT 变量。
    goto :fail
)

rem ---------- 前置检查：Node（优先系统 node，回退到托管版本）----------
set "NODE_EXE="
for /f "delims=" %%i in ('where node 2^>nul') do (
    if not defined NODE_EXE set "NODE_EXE=%%i"
)
if not defined NODE_EXE (
    if exist "%USERPROFILE%\.workbuddy\binaries\node\versions\22.22.2\node.exe" (
        set "NODE_EXE=%USERPROFILE%\.workbuddy\binaries\node\versions\22.22.2\node.exe"
    )
)
if not defined NODE_EXE (
    echo  [错误] 未找到 Node.js，请先安装或把它加入 PATH。
    goto :fail
)
echo  [OK] Node: %NODE_EXE%

rem ---------- 端口占用检查 ----------
netstat -ano -p tcp | findstr /R /C:":%PROXY_PORT% .*LISTENING" >nul 2>&1
if %errorlevel%==0 (
    echo  [警告] 端口 %PROXY_PORT% 已被占用，可能已有代理在运行。
    echo         继续启动会失败，请先关闭占用该端口的进程。
    goto :fail
)

echo.
echo  [1/3] 启动 Flutter dev server（新窗口，首次编译约需 1-3 分钟）...
start "Flutter Dev Server" cmd /k "cd /d "%PROJECT_ROOT%\client" && "%FLUTTER_BAT%" run -d web-server --web-port=%FLUTTER_PORT%"

echo  [2/3] 等待 dev server 就绪...
set "READY=0"
for /l %%i in (1,1,60) do (
    timeout /t 3 /nobreak >nul
    netstat -ano -p tcp | findstr /R /C:":%FLUTTER_PORT% .*LISTENING" >nul 2>&1
    if !errorlevel!==0 (
        set "READY=1"
        echo         dev server 已在 %FLUTTER_PORT% 端口就绪。
        goto :devserver_ready
    )
)
:devserver_ready
if "%READY%"=="0" (
    echo  [警告] 等待超时，dev server 可能仍在编译。
    echo         代理会先启动，请稍候刷新浏览器。
)

echo  [3/3] 启动开发代理（新窗口）...
start "Web Dev Proxy" cmd /k "cd /d "%PROJECT_ROOT%" && set PROXY_PORT=%PROXY_PORT%&& set FLUTTER_PORT=%FLUTTER_PORT%&& set API_TARGET=%API_TARGET%&& "%NODE_EXE%" scripts\web_dev_proxy.mjs"

timeout /t 3 /nobreak >nul
start "" "http://127.0.0.1:%PROXY_PORT%"

echo.
echo  ══════════════════════════════════════════════════════
echo    就绪！请在浏览器中访问：
echo.
echo        http://127.0.0.1:%PROXY_PORT%
echo.
echo    ⚠ 当前指向生产后端 %API_TARGET%
echo      开发期的发帖/点赞等写操作会写入生产数据库。
echo      如需隔离，请修改本脚本的 API_TARGET 指向测试环境。
echo  ══════════════════════════════════════════════════════
echo.
echo  提示：保持那两个窗口开启；关闭它们即可停止对应服务。
echo.
popd
endlocal
exit /b 0

:fail
echo.
echo  启动失败，请修正上述问题后重试。
echo.
popd
endlocal
exit /b 1
