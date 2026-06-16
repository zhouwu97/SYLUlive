import os
import re
import socket
import secrets

def get_local_ip():
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        # 不必真正连接，只需向公网IP发送一下请求以获得默认路由的网卡IP
        s.connect(('10.255.255.255', 1))
        IP = s.getsockname()[0]
    except Exception:
        IP = '127.0.0.1'
    finally:
        s.close()
    return IP

def update_launch_json(ip_address):
    launch_path = os.path.join("client", ".vscode", "launch.json")
    
    if not os.path.exists(launch_path):
        print(f"\n[!] 找不到 {launch_path}，无法自动配置 VSCode 运行参数。")
        return
        
    with open(launch_path, "r", encoding="utf-8") as f:
        content = f.read()
    
    content = re.sub(
        r'"--dart-define=(?:APP_API_URL|API_URL)=http://[^:]+:8080/api"',
        f'"--dart-define=APP_API_URL=http://{ip_address}:8080/api"',
        content
    )
    
    content = re.sub(
        r'"--dart-define=EDU_URL=http://[^:]+:8000"',
        f'"--dart-define=EDU_URL=http://{ip_address}:8000"',
        content
    )
    
    with open(launch_path, "w", encoding="utf-8") as f:
        f.write(content)
        
    print(f"\n[√] 客户端配置完成！")
    print(f"    - 已更新 client/.vscode/launch.json")
    print(f"    - 当前开发环境 IP: {ip_address}")

def update_server_env(env_updates):
    server_env_path = os.path.join("server", ".env")
    
    if not os.path.exists(server_env_path):
        print(f"\n[*] 找不到 {server_env_path}，将从 .env.example 复制...")
        example_path = os.path.join("server", ".env.example")
        if os.path.exists(example_path):
            with open(example_path, "r", encoding="utf-8") as f:
                content = f.read()
            content = content.replace("JWT_SECRET=", f"JWT_SECRET={secrets.token_hex(32)}")
            content = content.replace("DSN=host=127.0.0.1 port=5432 user=shenliyuan password=your_password dbname=shenliyuan sslmode=disable", "DSN=sqlite.db")
        else:
            print("[!] 找不到 server/.env.example，将创建全新的 .env 文件...")
            content = f"JWT_SECRET={secrets.token_hex(32)}\nDSN=sqlite.db\nPORT=8080\n"
    else:
        with open(server_env_path, "r", encoding="utf-8") as f:
            content = f.read()

    # Apply updates
    lines = content.split('\n')
    for key, value in env_updates.items():
        found = False
        for i, line in enumerate(lines):
            if line.startswith(f"{key}="):
                lines[i] = f"{key}={value}"
                found = True
                break
        if not found:
            lines.append(f"{key}={value}")
            
    content = '\n'.join(lines)
    
    # 确保不要有太多空行
    content = re.sub(r'\n{3,}', '\n\n', content)

    with open(server_env_path, "w", encoding="utf-8") as f:
        f.write(content.strip() + "\n")
        
    print(f"\n[√] 服务端配置完成！")
    print(f"    - 已更新 server/.env")

def setup_client_env():
    print("\n" + "-"*40)
    print("▶ 1. 自动获取局域网 IP (推荐，用于手机连接调试)")
    print("▶ 2. 使用 localhost (仅支持电脑模拟器/桌面端调试)")
    print("▶ 3. 手动输入 IP 或域名 (用于服务器部署与连接)")
    print("▶ 0. 取消")
    
    choice = input("\n请选择要配置的客户端连接地址 [1/2/3/0]: ").strip()
    
    if choice == '1':
        ip = get_local_ip()
        print(f"\n[*] 检测到本机局域网 IP: {ip}")
        confirm = input("确认使用此 IP 吗？[Y/n]: ").strip().lower()
        if confirm == 'n':
            return
        update_launch_json(ip)
    elif choice == '2':
        update_launch_json("127.0.0.1")
    elif choice == '3':
        ip = input("\n请输入目标服务器 IP 或域名 (例如: api.example.com 或 192.168.1.100): ").strip()
        if ip:
            update_launch_json(ip)
    elif choice == '0':
        return
    else:
        print("\n[!] 无效选项。")

def setup_smtp():
    print("\n" + "-"*40)
    print("▶ SMTP 邮件服务配置 (用于系统发送验证码等邮件)")
    email = input("\n请输入您的发件邮箱地址 (例如: your_qq_email@qq.com): ").strip()
    if not email:
        print("[!] 邮箱不能为空，已取消。")
        return
        
    password = input("请输入邮箱 SMTP 授权码 (不是登录密码): ").strip()
    if not password:
        print("[!] 授权码不能为空，已取消。")
        return
        
    host = "smtp.qq.com" if email.endswith("@qq.com") else input("请输入 SMTP 服务器地址 (默认 smtp.qq.com): ").strip() or "smtp.qq.com"
    port = "465" if host == "smtp.qq.com" else input("请输入 SMTP 端口 (默认 465): ").strip() or "465"

    updates = {
        "SMTP_HOST": host,
        "SMTP_PORT": port,
        "SMTP_USER": email,
        "SMTP_PASSWORD": password
    }
    
    update_server_env(updates)
    print("\n[√] SMTP 配置成功！")

def main_menu():
    while True:
        print("\n" + "="*50)
        print(" 🚀 沈理校园 (SYLUlive) 极简环境配置向导 🚀")
        print("="*50)
        print("  [1] 🌐 客户端 IP 配置 (一键改 launch.json)")
        print("  [2] 📧 服务端发信邮箱 (SMTP 快速设置)")
        print("  [3] 🔄 一键全自动配置 (局域网无脑模式)")
        print("  [0] ❌ 退出向导")
        print("="*50)
        
        choice = input("\n请输入选项编号: ").strip()
        
        if choice == '1':
            setup_client_env()
        elif choice == '2':
            setup_smtp()
        elif choice == '3':
            ip = get_local_ip()
            print(f"\n[*] 将自动配置客户端连接至本机 IP: {ip}")
            update_launch_json(ip)
            print("\n[*] 提示: 若需发信功能，请继续选择 [2] 配置邮箱。")
        elif choice == '0':
            print("\n👋 配置结束，祝您开发愉快！\n")
            break
        else:
            print("\n[!] 无效的输入，请重新选择。")

if __name__ == "__main__":
    try:
        main_menu()
    except KeyboardInterrupt:
        print("\n\n👋 已取消，再见！\n")
