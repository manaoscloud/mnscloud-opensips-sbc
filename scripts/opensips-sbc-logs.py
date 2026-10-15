#!/usr/bin/env python3
"""Apply the SBC server Logs tab on OpenSIPS and bound the journal that holds its logs.

Run every minute by mnscloud-opensips-sbc-logs.timer. The level is applied live through the MI
`log_level` command on the mnscloud_sbc_fifo (no restart; every process) and re-applied after a
restart. OpenSIPS logs to syslog/journald, so the retention becomes the journald MaxRetentionSec of
the node; the per-call capture log is rotated like the other engines.
"""
import grp
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import threading

HERE = Path(__file__).resolve().parent
_spec = importlib.util.spec_from_file_location('mnscloud_engine_logs', HERE / 'mnscloud_engine_logs.py')
core = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(core)

IDENTITY = Path('/etc/mnscloud/sbc')
MI_DIR = Path('/run/opensips')
MI_FIFO = MI_DIR / 'mnscloud_sbc_fifo'
LOG_DIR = Path('/var/log/mnscloud/opensips')
# OpenSIPS levels: L_ERR=-1, L_WARN=1, L_NOTICE=2, L_INFO=3, L_DBG=4.
LOG_LEVEL = {'error': -1, 'warning': 1, 'notice': 2, 'info': 3, 'debug': 4}


def opensips_gid():
    try:
        return grp.getgrnam('opensips').gr_gid
    except KeyError:
        return 0


def mi(method, params, timeout=8):
    """One JSON-RPC call over the MI FIFO, as scripts/opensips-sbc-mi.sh does."""
    if not MI_FIFO.is_fifo():
        raise RuntimeError('OpenSIPS MI FIFO is not available')
    name = f'mnscloud_sbc_logs_{os.getpid()}'
    reply = MI_DIR / name
    reply.unlink(missing_ok=True)
    os.mkfifo(reply, 0o660)
    os.chown(reply, 0, opensips_gid())
    response = {}
    def read():
        with reply.open('rb') as source:
            response['body'] = source.read(64 * 1024)
    reader = threading.Thread(target=read, daemon=True)
    reader.start()
    try:
        payload = json.dumps({'jsonrpc': '2.0', 'method': method, 'params': params, 'id': name})
        descriptor = os.open(MI_FIFO, os.O_WRONLY | os.O_NONBLOCK)
        with os.fdopen(descriptor, 'w') as fifo:
            fifo.write(f':{name}:{payload}\n')
        reader.join(timeout)
    finally:
        if reader.is_alive():
            # Unblock the reader so the thread ends with the process.
            os.close(os.open(reply, os.O_WRONLY | os.O_NONBLOCK))
        reply.unlink(missing_ok=True)
    body = response.get('body', b'')
    if not body or b'"error"' in body:
        raise RuntimeError('OpenSIPS MI call failed: ' + method)
    return body


def main_pid():
    result = subprocess.run(['systemctl', 'show', '-p', 'MainPID', '--value', 'opensips'],
                            capture_output=True, text=True, timeout=10)
    return result.stdout.strip() or '0'


def apply(settings, previous):
    level = core.effective_level(settings, core.low_disk('/var/log'))
    marker = {'pid': main_pid(), 'level': level}
    if marker['pid'] == '0':
        return {'pid': '0', 'level': None}  # Not running: apply on the next refresh.
    if marker != previous:
        mi('log_level', {'level': LOG_LEVEL[level]})
    return marker


def maintain(settings):
    days = settings['logRetentionDays']
    if core.journald_retention(days):
        subprocess.run(['systemctl', 'restart', 'systemd-journald'], check=False, timeout=30)
    name = 'cdr-diagnostic-capture.log'
    rotated = core.rotate(LOG_DIR / name, core.STATE_ROOT / f'opensips-{name}-rotated',
                          (0, opensips_gid()), mode=0o660)
    deleted = core.purge(LOG_DIR, [f'{name}-*.gz', f'{name}.[0-9]*'], days)
    core.maintain_install_log(days)
    return {'rotated': str(rotated) if rotated else None, 'deleted': deleted, 'journalDays': days}


def fetch():
    base, node, token = core.read_identity(IDENTITY, 'api.token')
    return core.fetch_settings(base, 'sbc/runtime/log-config', node, token,
                               query={'engine': 'opensips'})


if __name__ == '__main__':
    os.environ.setdefault('LC_ALL', 'C')
    core.main('opensips-sbc', fetch, apply, maintain)
