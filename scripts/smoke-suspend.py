#!/usr/bin/env python3
"""Save and restore the production HVF/TPM machine using only temporary data."""
import json
import os
from pathlib import Path
import shutil
import socket
import subprocess
import tempfile
import time

root = Path(__file__).resolve().parent.parent
firmware_dir = root / 'Firmware'
firmware_code = firmware_dir / 'AAVMF_CODE.ms.fd'
firmware_vars = firmware_dir / 'AAVMF_VARS.ms.fd'
if not firmware_code.exists() or not firmware_vars.exists():
    raise RuntimeError('Run scripts/setup-firmware.sh before the smoke test')
engine = root / 'build/WindowVM.app/Contents/Helpers/WindowVM Engine.app/Contents/MacOS/WindowVMEngine'
if not engine.exists():
    raise RuntimeError('Run scripts/build.sh before the smoke test')
subprocess.run(['swift', 'build', '--product', 'VMSmoke'], cwd=root, check=True)
with tempfile.TemporaryDirectory(prefix='windowvm-') as temporary:
    directory = Path(temporary)
    shutil.copy(firmware_vars, directory / 'efi-vars.fd')
    subprocess.run(['/opt/homebrew/bin/qemu-img', 'create', '-f', 'qcow2', str(directory / 'windows.qcow2'), '1G'], check=True)
    tools = directory / 'tools'
    tools.mkdir()
    (tools / 'README.txt').write_text('WindowVM smoke test\n')
    subprocess.run(['/usr/bin/hdiutil', 'makehybrid', '-iso', '-joliet', '-o', str(directory / 'guest-tools.iso'), str(tools)], check=True, stdout=subprocess.DEVNULL)
    (directory / 'tpm').mkdir()
    log = open(directory / 'qemu.log', 'w+')
    tpm = subprocess.Popen(['/opt/homebrew/bin/swtpm', 'socket', '--tpm2', '--tpmstate', f'dir={directory / "tpm"}', '--ctrl', f'type=unixio,path={directory / "tpm.sock"}', '--flags', 'not-need-init'], stdout=log, stderr=log)
    qemu = None
    try:
        for _ in range(100):
            if (directory / 'tpm.sock').exists():
                break
            if tpm.poll() is not None:
                raise RuntimeError('TPM exited')
            time.sleep(0.05)
        args = json.loads(subprocess.check_output([str(root / '.build/debug/VMSmoke'), str(directory), str(firmware_code)]))
        qemu = subprocess.Popen([str(engine), *args], stdout=log, stderr=log)
        for _ in range(200):
            if qemu.poll() is not None:
                raise RuntimeError('QEMU exited before QMP became ready')
            if (directory / 'qmp.sock').exists():
                break
            time.sleep(0.05)
        client = socket.socket(socket.AF_UNIX)
        client.settimeout(8)
        client.connect(str(directory / 'qmp.sock'))
        reader = client.makefile('rb')
        greeting = json.loads(reader.readline())
        assert 'QMP' in greeting
        def command(name, arguments=None):
            request = {'execute': name, 'id': name}
            if arguments is not None:
                request['arguments'] = arguments
            client.sendall((json.dumps(request) + '\r\n').encode())
            while True:
                response = json.loads(reader.readline())
                if response.get('id') == name:
                    if 'error' in response:
                        raise RuntimeError(response['error'])
                    return response['return']
        command('qmp_capabilities')
        status = command('query-status')
        assert status['running'], status
        with socket.create_connection(('127.0.0.1', 28080), timeout=2):
            pass
        tpms = command('query-tpm')
        assert tpms and tpms[0]['model'] == 'tpm-tis', tpms
        time.sleep(4)
        screenshot = directory / 'firmware.ppm'
        command('screendump', {'filename': str(screenshot)})
        assert screenshot.stat().st_size > 100000
        artifact = root / 'build/firmware-smoke.png'
        artifact.parent.mkdir(exist_ok=True)
        subprocess.run(['/usr/bin/sips', '-s', 'format', 'png', str(screenshot), '--out', str(artifact)], check=True, stdout=subprocess.DEVNULL)
        # A successful query-status proves HVF started: the production plan has no TCG fallback.
        command('stop')
        print('Migration blockers:', command('query-migrate'), flush=True)
        state = directory / 'suspend.bin'
        command('migrate', {'channels':[{'channel-type':'main','addr':{'transport':'file','filename':str(state),'offset':0}}]})
        for _ in range(600):
            progress=command('query-migrate')
            if progress.get('status') in ('completed','failed','cancelled'): break
            time.sleep(.1)
        print('Save result:',progress, flush=True)
        assert progress.get('status')=='completed', progress
        command('quit')
        qemu.wait(timeout=10)
        assert qemu.returncode == 0
        client.close(); reader.close()
        tpm.terminate(); tpm.wait(timeout=5)
        for name in ['qmp.sock','tpm.sock','tpm.sock.ctrl','qemu.pid']:
            (directory/name).unlink(missing_ok=True)
        tpm=subprocess.Popen(['/opt/homebrew/bin/swtpm','socket','--tpm2','--tpmstate',f'dir={directory / "tpm"}','--ctrl',f'type=unixio,path={directory / "tpm.sock"}','--flags','not-need-init'],stdout=log,stderr=log)
        for _ in range(100):
            if (directory/'tpm.sock').exists():break
            time.sleep(.05)
        qemu=subprocess.Popen([str(engine), *args, '-incoming','defer','-S'],stdout=log,stderr=log)
        for _ in range(200):
            if qemu.poll() is not None:raise RuntimeError('restore launch failed')
            if (directory/'qmp.sock').exists():break
            time.sleep(.05)
        client=socket.socket(socket.AF_UNIX);client.settimeout(15);client.connect(str(directory/'qmp.sock'));reader=client.makefile('rb')
        json.loads(reader.readline());command('qmp_capabilities')
        command('migrate-incoming',{'channels':[{'channel-type':'main','addr':{'transport':'file','filename':str(state),'offset':0}}]})
        for _ in range(600):
            progress=command('query-migrate')
            if progress.get('status') in ('completed','failed','cancelled'):break
            time.sleep(.1)
        print('Restore result:',progress,flush=True)
        assert progress.get('status')=='completed',progress
        command('cont');assert command('query-status')['running']
        command('quit');qemu.wait(timeout=10)
        print('PASS: suspend/resume round trip; production launch plan, HVF boot, TPM 2.0, NVMe, NAT/forward listener, framebuffer, QMP shutdown request')
        print('Screenshot:', artifact)
    except Exception:
        log.flush()
        log.seek(0)
        print(log.read())
        raise
    finally:
        if qemu is not None and qemu.poll() is None:
            qemu.terminate()
            try:
                qemu.wait(timeout=5)
            except subprocess.TimeoutExpired:
                qemu.kill()
                qemu.wait()
        tpm.terminate()
        tpm.wait(timeout=5)
        log.close()
