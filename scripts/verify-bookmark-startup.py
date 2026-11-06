"""Run the actual server against a fresh disposable PostgreSQL cluster.

No external DSN is accepted. The harness binds loopback and always stops the
dedicated cluster. Evidence contains synthetic data and no credentials.
"""
import argparse
import base64
import hashlib
import hmac
import json
import os
from pathlib import Path
import secrets
import socket
import subprocess
import tempfile
import time
import urllib.error
import urllib.request


def free_port():
    with socket.socket() as sock:
        sock.bind(('127.0.0.1', 0))
        return sock.getsockname()[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path, required=True)
    parser.add_argument('--pg-bin', type=Path, required=True)
    parser.add_argument('--competition-migrator', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--expect', choices=['missing', 'present'], default='present')
    args = parser.parse_args()
    binary = args.binary.resolve(strict=True)
    pg_bin = args.pg_bin.resolve(strict=True)
    temp = Path(tempfile.mkdtemp(prefix='sylulive-bookmark-disposable-'))
    (temp/'DISPOSABLE_TEST_ONLY').write_text('Fresh synthetic cluster. No production data.\n')
    secret, jwt_secret, pg_port, web_port = secrets.token_urlsafe(32), secrets.token_urlsafe(48), free_port(), free_port()
    password = temp/'init-password.txt'
    password.write_text(secret)
    env = {k:v for k,v in os.environ.items() if not k.endswith('_DSN') and k not in ('DSN','DATABASE_URL','GIN_MODE')}
    env.update(PGUSER='bookmarkqa', PGPASSWORD=secret, PGHOST='127.0.0.1', PGPORT=str(pg_port))
    no_window = getattr(subprocess, 'CREATE_NO_WINDOW', 0)
    started, server, log = False, None, None
    result = {'expectation':args.expect, 'fresh_cluster':True, 'loopback_only':True, 'checks':[]}

    def pg(command, *params, query=False):
        with (temp/'admin.log').open('ab') as output:
            process = subprocess.run([str(pg_bin/(command + ('.exe' if os.name == 'nt' else ''))), *params],
                env=env, cwd=temp, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE if query else output,
                stderr=output, timeout=120, creationflags=no_window)
        if process.returncode:
            raise RuntimeError(f'Disposable PostgreSQL command failed: {command}')
        return process.stdout.decode('utf-8').strip() if query else None

    def sql(statement):
        return pg('psql','-X','-v','ON_ERROR_STOP=1','-At','-d','bookmarkqa','-c',statement,query=True)

    def request(path, method='GET', token=None):
        headers = {'Authorization':'Bearer '+token} if token else {}
        req = urllib.request.Request(f'http://127.0.0.1:{web_port}'+path, method=method, headers=headers)
        try:
            with urllib.request.urlopen(req,timeout=3) as response:
                return response.status, json.load(response)
        except urllib.error.HTTPError as error:
            return error.code, json.load(error)

    def token(user, role, version):
        def encode(value):
            return base64.urlsafe_b64encode(json.dumps(value,separators=(',',':')).encode()).rstrip(b'=')
        body = encode({'alg':'HS256','typ':'JWT'})+b'.'+encode({'user_id':user,'role':role,'token_version':version,'exp':int(time.time())+600})
        return (body+b'.'+base64.urlsafe_b64encode(hmac.new(jwt_secret.encode(),body,hashlib.sha256).digest()).rstrip(b'=')).decode()

    def boot():
        nonlocal server, log
        log = (temp/'server.log').open('ab')
        server = subprocess.Popen([str(binary)],cwd=temp,env=server_env,stdin=subprocess.DEVNULL,stdout=log,stderr=subprocess.STDOUT,creationflags=no_window)
        deadline = time.monotonic()+90
        while time.monotonic()<deadline:
            if server.poll() is not None:
                raise RuntimeError('Server exited during startup; inspect synthetic server.log')
            try:
                code,_ = request('/health')
                if code == 200:
                    return
            except (OSError, ValueError):
                pass
            time.sleep(.2)
        raise RuntimeError('Server startup timed out')

    def stop_server():
        nonlocal server, log
        if server and server.poll() is None:
            server.terminate()
            try:
                server.wait(timeout=15)
            except subprocess.TimeoutExpired:
                server.kill(); server.wait(timeout=10)
        server = None
        if log:
            log.close(); log = None

    try:
        pg('initdb','-D',str(temp/'data'),'-U','bookmarkqa','--pwfile',str(password),
            '--auth-host=scram-sha-256','--auth-local=scram-sha-256','--encoding=UTF8','--locale=C')
        password.unlink()
        pg('pg_ctl','-D',str(temp/'data'),'-l',str(temp/'postgres.log'),'-o',f'-h 127.0.0.1 -p {pg_port}', '-w','start')
        started = True
        pg('createdb','bookmarkqa')
        # This existing permission subsystem has mandatory SQL constraints in
        # addition to AutoMigrate. Seed its documented prerequisite, not bookmarks.
        sql('CREATE TABLE users (id bigserial PRIMARY KEY)')
        for migration in ('20260725_ai_user_permissions.sql','20260726_ai_external_model_permission.sql'):
            pg('psql','-X','-v','ON_ERROR_STOP=1','-d','bookmarkqa','-f',str(Path(__file__).resolve().parents[1]/'server'/'sql'/migration))
        server_env = dict(env, DSN=f'host=127.0.0.1 port={pg_port} user=bookmarkqa password={secret} dbname=bookmarkqa sslmode=disable',
            JWT_SECRET=jwt_secret, SUPER_ADMIN_ID='synthetic-bookmark-admin', SUPER_ADMIN_PASSWORD=secrets.token_urlsafe(32),
            SERVER_LISTEN_ADDR=f'127.0.0.1:{web_port}', UPLOAD_DIR=str(temp/'uploads'), EXAM_PAPER_DIR=str(temp/'papers'),
            COMPETITION_AWARD_EVIDENCE_DIR=str(temp/'evidence'), EXAM_PAPER_STORAGE_MODE='local',
            AI_ENABLED='false',JWC_SYNC_ENABLED='false',INTEGRATION_ENABLED='false',GIN_MODE='test')
        with (temp/'prerequisite-migration.log').open('ab') as migration_log:
            subprocess.run([str(args.competition_migrator.resolve(strict=True)),'--apply','--backup-confirmed'],
                env=server_env,cwd=temp,stdin=subprocess.DEVNULL,stdout=migration_log,stderr=subprocess.STDOUT,
                check=True,timeout=120,creationflags=no_window)
        boot()
        result['checks'].append('actual_binary_started')
        exists = sql("SELECT to_regclass('public.post_bookmarks') IS NOT NULL") == 't'
        user, role, version = sql("SELECT id,role,token_version FROM users WHERE student_id='synthetic-bookmark-admin'").split('|')
        auth = token(int(user),role,int(version))
        status, body = request('/api/user/bookmarks',token=auth)
        if args.expect == 'missing':
            assert not exists and status == 500, (exists,status)
            result['checks'].append('missing_table_reproduces_http_500')
        else:
            assert exists and status == 200 and not body['posts'], (exists,status)
            result['checks'].append('fresh_start_creates_table_and_empty_list')
            post = sql(f"INSERT INTO posts (author_id,title,content,board_id,post_type,status,content_kind,created_at,updated_at) VALUES ({int(user)},'Synthetic bookmark','Synthetic public text',1,'campus_life','normal','normal',now(),now()) RETURNING id").splitlines()[0]
            for _ in range(2):
                assert request(f'/api/posts/{post}/bookmark','PUT',auth)[0] == 200
            assert sql('SELECT count(*) FROM post_bookmarks') == '1'
            result['checks'].append('authenticated_idempotent_bookmark')
            assert request('/api/user/bookmarks')[0] == 401
            result['checks'].append('anonymous_access_rejected')
            stop_server(); boot()
            assert sql('SELECT count(*) FROM post_bookmarks') == '1'
            status, body = request('/api/user/bookmarks',token=auth)
            assert status == 200 and str(body['posts'][0]['id']) == post
            result['checks'].append('restart_preserves_bookmark_and_list')
            for _ in range(2):
                assert request(f'/api/posts/{post}/bookmark','DELETE',auth)[0] == 200
            assert sql('SELECT count(*) FROM post_bookmarks') == '0'
            result['checks'].append('authenticated_idempotent_remove')
        result['passed'] = True
    except Exception as error:
        result['passed'], result['error_type'] = False, type(error).__name__
        raise
    finally:
        stop_server()
        password.unlink(missing_ok=True)
        if started or (temp/'data'/'postmaster.pid').exists():
            pg('pg_ctl','-D',str(temp/'data'),'-m','immediate','-w','-t','30','stop')
        result['cluster_stopped'], result['synthetic_logs'] = True, str(temp)
        args.output.write_text(json.dumps(result,indent=2),encoding='utf-8')
        print(json.dumps(result))


if __name__ == '__main__':
    main()
