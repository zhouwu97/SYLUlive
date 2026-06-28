"""应用配置"""
import os

# 数据库配置
DATABASE_URL = os.getenv("DATABASE_URL", "sqlite+aiosqlite:///./database/edu.db")

# 教务系统URL
INDEX_URL = "https://jxw.sylu.edu.cn/xtgl"
COURSE_URL = "https://jxw.sylu.edu.cn/kbcx"
GRADE_URL = "https://jxw.sylu.edu.cn/cjcx"

# 服务器配置
HOST = os.getenv("HOST", "0.0.0.0")
PORT = int(os.getenv("PORT", "8081"))

# 内部服务认证
INTERNAL_SERVICE_TOKEN = os.getenv("INTERNAL_SERVICE_TOKEN", "")
JWC_CRAWLER_CONTACT = os.getenv("JWC_CRAWLER_CONTACT", "")

# 默认课时设置（分钟）
DEFAULT_CLASS_DURATION = 45
DEFAULT_BREAK_DURATION = 10
