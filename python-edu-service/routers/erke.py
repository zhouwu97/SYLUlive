from fastapi import APIRouter, Depends, HTTPException, Body
from pydantic import BaseModel
from typing import Optional
from erke_crawler import SyluCrawler
from services.security import require_internal_service

# 该路由代持 VPN 与二课凭据并回传会话结果，必须做服务间认证。
router = APIRouter(
    prefix="/erke",
    tags=["二课服务"],
    dependencies=[Depends(require_internal_service)],
)

class ErkeLoginRequest(BaseModel):
    vpn_username: str
    vpn_password: str
    erke_username: str
    erke_password: str

@router.post("/scores")
async def get_erke_scores(req: ErkeLoginRequest):
    """
    获取二课成绩
    """
    crawler = SyluCrawler()

    # 1. 登录 VPN
    vpn_res = crawler.vpn_login(req.vpn_username, req.vpn_password)
    if not vpn_res["success"]:
        return vpn_res

    # 2. 登录二课
    login_res = crawler.login(req.erke_username, req.erke_password)
    if not login_res["success"]:
        return login_res

    # 3. 获取成绩
    score_res = crawler.get_scores()
    return score_res
