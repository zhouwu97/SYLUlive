import paramiko

def run_cmd():
    cmd = """
    BACKUP_DIR="/opt/shenliyuan/backup_$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$BACKUP_DIR"
    sudo -u postgres pg_dump shenliyuan > "$BACKUP_DIR/db_shenliyuan.sql"
    cp -r /opt/shenliyuan/uploads "$BACKUP_DIR/"
    cp /opt/shenliyuan/shenliyuan "$BACKUP_DIR/"
    cp /opt/shenliyuan/.env "$BACKUP_DIR/"
    cd /opt/shenliyuan
    tar -czf "${BACKUP_DIR}.tar.gz" -C "$BACKUP_DIR" .
    rm -rf "$BACKUP_DIR"
    echo "Backup created at: ${BACKUP_DIR}.tar.gz"
    ls -la "${BACKUP_DIR}.tar.gz"
    """
    ssh = paramiko.SSHClient()
    ssh.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    try:
        ssh.connect('156.233.229.232', port=22, username='root', password='M7J6E3TNj42V', timeout=10)
        stdin, stdout, stderr = ssh.exec_command(cmd)
        print("STDOUT:")
        print(stdout.read().decode())
        print("STDERR:")
        print(stderr.read().decode())
    except Exception as e:
        print(f"Error: {e}")
    finally:
        ssh.close()

if __name__ == '__main__':
    run_cmd()
