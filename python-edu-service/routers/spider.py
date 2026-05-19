"""
爬虫 API 路由 — 供 Go 后端通过 HTTP 调用

架构:
  Flutter → Go Backend (Gin, :8080) → Python FastAPI (:8000) → SyluCrawler → WebVPN → 二课系统

端点:
  POST /api/spider/erke    二课成绩抓取
"""

from fastapi import APIRouter, HTTPException
from pydantic import BaseModel, Field
from typing import Optional

from erke_crawler import SyluCrawler

# ── 路由定义 ──────────────────────────────────────────────────
router = APIRouter(prefix="/api/spider", tags=["爬虫服务"])


# ── Pydantic 请求模型 ────────────────────────────────────────

class SpiderRequest(BaseModel):
    """Go 后端 → Python 爬虫服务的请求体"""
    username: str = Field(
        ...,
        min_length=1,
        max_length=20,
        description="学号",
        example="2101010101",
    )
    password: str = Field(
        ...,
        min_length=1,
        max_length=64,
        description="二课系统密码（明文，Python 侧负责 RSA 加密）",
    )
    vpn_ticket: Optional[str] = Field(
        default=None,
        description=(
            "WebVPN 认证票据 (wengine_vpn_ticketwebvpn_sylu_edu_cn)。"
            "如果用户已在外网完成 VPN 认证，传入此值可跳过 VPN 登录步骤。"
            "若为空，则需确保 Go 后端已注入 Cookie 到爬虫实例。"
        ),
    )


# ── 响应模型 ──────────────────────────────────────────────────

class SpiderResponse(BaseModel):
    """统一响应格式"""
    code: int = Field(description="业务状态码，200=成功")
    message: str = Field(description="提示信息")
    data: Optional[dict] = Field(default=None, description="返回数据")


# ── API 端点 ──────────────────────────────────────────────────

@router.post(
    "/erke",
    response_model=SpiderResponse,
    summary="二课成绩抓取",
    description="通过深信服 WebVPN 登录二课系统并获取成绩数据",
)
def fetch_erke_score(req: SpiderRequest):
    """
    二课成绩抓取接口

    工作流:
      1. 接收 Go 后端传入的学号、密码、VPN Ticket
      2. 创建 SyluCrawler 实例（注入 VPN Ticket 穿透外网）
      3. 执行登录: GET 登录页 → 提取 Token/公钥 → OCR 验证码 → RSA 加密 → POST 登录
      4. 登录成功后获取二课成绩列表
      5. 返回标准 JSON 给 Go 后端

    Go 后端调用示例:
      POST http://127.0.0.1:8000/api/spider/erke
      Content-Type: application/json
      {
        "username": "2101010101",
        "password": "mypassword",
        "vpn_ticket": "xxxxx"
      }
    """
    try:
        # ── 1. 初始化爬虫 ──────────────────────────────
        crawler = SyluCrawler(vpn_ticket=req.vpn_ticket)

        # ── 2. 登录二课系统 ────────────────────────────
        login_result = crawler.login(req.username, req.password)

        if not login_result.get("success"):
            return SpiderResponse(
                code=401,
                message=login_result.get("message", "登录失败"),
                data=None,
            )

        # ── 3. 获取二课成绩 ────────────────────────────
        score_result = crawler.get_scores()

        if not score_result.get("success"):
            return SpiderResponse(
                code=502,
                message=score_result.get("message", "成绩获取失败"),
                data=None,
            )

        # ── 4. 附带回当前 Session Cookie ───────────────
        #     Go 后端可存入数据库，后续请求复用，避免重复登录
        cookies = crawler.export_cookies()

        return SpiderResponse(
            code=200,
            message="success",
            data={
                "scores": score_result.get("data", []),
                "cookies": cookies,
            },
        )

    except Exception as e:
        # 未预期的运行时错误 (如 ddddocr 模型加载失败、网络中断等)
        raise HTTPException(
            status_code=500,
            detail=f"爬取失败: {str(e)}",
        )


@router.post(
    "/erke/login",
    response_model=SpiderResponse,
    summary="二课登录 (仅验证，不拉取数据)",
    description="仅执行登录验证，返回 Session Cookie 供后续复用",
)
def erke_login_only(req: SpiderRequest):
    """
    二课登录验证接口 (不抓取成绩)

    适用场景: Go 后端需要预先验证账号有效性，存储 Cookie 供后续批量查询使用。

    返回:
      - 登录成功: data.cookies 包含完整的 Session Cookie 字典
      - 登录失败: code 非 200，message 包含错误原因
    """
    try:
        crawler = SyluCrawler(vpn_ticket=req.vpn_ticket)
        login_result = crawler.login(req.username, req.password)

        if not login_result.get("success"):
            return SpiderResponse(
                code=401,
                message=login_result.get("message", "登录失败"),
                data=None,
            )

        cookies = crawler.export_cookies()

        return SpiderResponse(
            code=200,
            message="登录验证成功",
            data={
                "cookies": cookies,
                "redirect_url": login_result.get("data", {}).get("redirect_url", ""),
            },
        )

    except Exception as e:
        raise HTTPException(
            status_code=500,
            detail=f"登录验证失败: {str(e)}",
        )
