"""认证路由 - 绑定/解绑教务账号"""
from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy import select

from models.database import EduUser, get_db
from models.schemas import BindInput, BindResponse, UnbindResponse, EduStatusResponse, ErrorResponse, PreVerifyResponse, PreVerifyInput, LoginEduInput, LoginEduResponse
from services.crawler import EduCrawler, CookieLapseError, LoginFailedError, NetworkError
from services.credential_crypto import encrypt_credential, decrypt_credential

router = APIRouter(prefix="/api/edu", tags=["认证"])


@router.post("/pre_verify", response_model=PreVerifyResponse)
async def pre_verify_edu_account(
    input: PreVerifyInput,
):
    """预验证教务账号（注册前验证学号和密码是否匹配）"""
    async with EduCrawler() as crawler:
        try:
            # 1. 尝试登录教务系统
            cookie = await crawler.login(input.student_id, input.password)

            # 2. 获取学生信息
            student_info = await crawler.get_student_info(cookie, input.student_id)

            return PreVerifyResponse(
                success=True,
                message="验证成功",
                student_id=input.student_id,
                name=student_info.name
            )

        except LoginFailedError as e:
            return PreVerifyResponse(
                success=False,
                message=str(e)
            )
        except CookieLapseError as e:
            return PreVerifyResponse(
                success=False,
                message=str(e)
            )
        except NetworkError as e:
            return PreVerifyResponse(
                success=False,
                message=f"网络错误: {str(e)}"
            )
        except Exception as e:
            return PreVerifyResponse(
                success=False,
                message=f"验证失败: {str(e)}"
            )


@router.post("/bind", response_model=BindResponse)
async def bind_edu_account(
    input: BindInput,
    db: AsyncSession = Depends(get_db)
):
    """绑定教务账号"""
    async with EduCrawler() as crawler:
        try:
            # 1. 登录教务系统
            cookie = await crawler.login(input.student_id, input.password)

            # 2. 获取学生信息
            student_info = await crawler.get_student_info(cookie, input.student_id)

            # 3. 存储到数据库
            # 检查是否已存在
            result = await db.execute(
                select(EduUser).where(EduUser.user_id == input.user_id)
            )
            existing_user = result.scalar_one_or_none()

            if existing_user:
                # 更新
                existing_user.student_id = input.student_id
                existing_user.name = student_info.name
                existing_user.encrypted_password = encrypt_credential(input.password)
                existing_user.cookie = cookie
                existing_user.grade = student_info.grade
                existing_user.college = student_info.college
                existing_user.major = student_info.major
                existing_user.bound = True
            else:
                # 新建
                edu_user = EduUser(
                    user_id=input.user_id,
                    student_id=input.student_id,
                    name=student_info.name,
                    encrypted_password=encrypt_credential(input.password),
                    cookie=cookie,
                    grade=student_info.grade,
                    college=student_info.college,
                    major=student_info.major,
                    bound=True
                )
                db.add(edu_user)

            await db.commit()

            return BindResponse(
                success=True,
                message="绑定成功",
                student_id=input.student_id,
                name=student_info.name,
                grade=student_info.grade,
                college=student_info.college,
                major=student_info.major
            )

        except LoginFailedError as e:
            raise HTTPException(status_code=401, detail=str(e))
        except CookieLapseError as e:
            raise HTTPException(status_code=401, detail=str(e))
        except NetworkError as e:
            raise HTTPException(status_code=503, detail=str(e))
        except Exception as e:
            await db.rollback()
            raise HTTPException(status_code=500, detail=f"绑定失败: {str(e)}")


@router.delete("/bind", response_model=UnbindResponse)
async def unbind_edu_account(
    user_id: str,
    db: AsyncSession = Depends(get_db)
):
    """解绑教务账号"""
    result = await db.execute(
        select(EduUser).where(EduUser.user_id == user_id)
    )
    edu_user = result.scalar_one_or_none()

    if not edu_user:
        return UnbindResponse(success=True, message="未绑定，无需解绑")

    # Clear sensitive data instead of deleting row? 
    # The requirement said: "Python 删除密码、Cookie、bound 状态"
    edu_user.encrypted_password = ""
    edu_user.cookie = ""
    edu_user.bound = False
    
    # Or db.delete(edu_user)? "删除密码、Cookie、bound 状态" implies updating. 
    # But db.delete is also fine. I will update it just in case:
    await db.delete(edu_user)
    await db.commit()

    return UnbindResponse(success=True, message="解绑成功")


@router.get("/status", response_model=EduStatusResponse)
async def get_edu_status(
    user_id: str,
    db: AsyncSession = Depends(get_db)
):
    """获取教务绑定状态"""
    result = await db.execute(
        select(EduUser).where(EduUser.user_id == user_id)
    )
    edu_user = result.scalar_one_or_none()

    if not edu_user or not edu_user.bound:
        return EduStatusResponse(bound=False)

    return EduStatusResponse(
        bound=True,
        student_id=edu_user.student_id,
        name=edu_user.name,
        grade=edu_user.grade,
        college=edu_user.college,
        major=edu_user.major
    )


@router.post("/refresh_cookie")
async def refresh_cookie(
    user_id: str,
    db: AsyncSession = Depends(get_db)
):
    """刷新过期的Cookie"""
    result = await db.execute(
        select(EduUser).where(EduUser.user_id == user_id)
    )
    edu_user = result.scalar_one_or_none()

    if not edu_user or not edu_user.bound:
        raise HTTPException(status_code=400, detail="未绑定教务账号")

    if not edu_user.encrypted_password:
        raise HTTPException(status_code=401, detail="无有效的凭据，请重新绑定教务账号")

    try:
        password = decrypt_credential(edu_user.encrypted_password)
    except Exception:
        raise HTTPException(status_code=401, detail="凭据解密失败，请重新绑定教务账号")

    async with EduCrawler() as crawler:
        try:
            new_cookie = await crawler.login(edu_user.student_id, password)
            edu_user.cookie = new_cookie
            await db.commit()
            return {"success": True, "message": "Cookie刷新成功"}
        except (LoginFailedError, CookieLapseError, NetworkError) as e:
            raise HTTPException(status_code=401, detail=str(e))


@router.post("/login_edu", response_model=LoginEduResponse)
async def login_edu_account(
    input: LoginEduInput,
):
    """统一登录（验证教务+获取信息，返回给Go服务器）"""
    async with EduCrawler() as crawler:
        try:
            # 1. 登录教务系统
            cookie = await crawler.login(input.student_id, input.edu_password)

            # 2. 获取学生信息
            student_info = await crawler.get_student_info(cookie, input.student_id)

            return LoginEduResponse(
                success=True,
                message="验证成功",
                student_id=input.student_id,
                name=student_info.name,
                grade=student_info.grade,
                college=student_info.college,
                major=student_info.major
            )

        except LoginFailedError as e:
            return LoginEduResponse(success=False, message="教务密码错误")
        except CookieLapseError as e:
            return LoginEduResponse(success=False, message=str(e))
        except NetworkError as e:
            return LoginEduResponse(success=False, message=f"网络错误: {str(e)}")
        except Exception as e:
            return LoginEduResponse(success=False, message=f"验证失败: {str(e)}")
