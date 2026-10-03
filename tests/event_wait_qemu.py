#!/usr/bin/env python3
"""Real PS/2/QMP event-wait acceptance; stdlib only, isolated test build.

EVENT_WAIT_OPT=-O2 EVENT_WAIT_BOOT=iso python3 tests/event_wait_qemu.py
Screenshots and the deterministic event trace survive in build/event-wait/.
"""
import argparse
import json
import os
from pathlib import Path
import shutil
import socket
import struct
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]


def run(args):
    subprocess.run([str(a) for a in args], cwd=ROOT, check=True,
                   stdout=subprocess.PIPE, stderr=subprocess.PIPE)


def build(tmp, opt, boot, extra_sources=(), extra_wrappers=(), extra_defines=()):
    cc = os.environ.get('CROSS_CC') or shutil.which('i686-elf-gcc')
    nm = os.environ.get('CROSS_NM') or shutil.which('i686-elf-nm')
    zc = os.environ.get('ZC') or shutil.which('zc')
    flags = ['-m32', '-ffreestanding', '-fno-pie', '-fno-pic',
             '-fno-stack-protector', '-fno-builtin', opt]
    objects = []
    sources = [ROOT / 'arch/i686/io.zc', *sorted((ROOT / 'kernel').glob('*.zc'))]
    sources += [ROOT / 'arch/i686' / name for name in ('boot.S', 'interrupts.S', 'tasks.S')]
    sources += [ROOT / 'tests/event_wait_fixture.c', ROOT / 'tests/event_wait_context.S']
    sources += list(extra_sources)
    for index, source in enumerate(sources):
        obj = tmp / f'{index}.o'
        if source.suffix == '.zc':
            generated = tmp / f'{index}.c'
            run([zc, 'transpile', '--freestanding', source, '-o', generated])
            source = generated
        run([cc, *flags, '-DZC_FUNC=', '-DZC_GLOBAL=', '-DZOS_EVENT_WAIT_TEST',
             *['-D' + define for define in extra_defines],
             '-c', source, '-o', obj])
        objects.append(obj)
    elf = tmp / 'event-wait.elf'
    run([cc, *flags, '-nostdlib', '-T', ROOT / 'arch/i686/linker.ld',
         '-Wl,--wrap=task_create', *['-Wl,--wrap=' + name for name in extra_wrappers],
         '-o', elf, *objects, '-lgcc'])
    output = subprocess.check_output([nm, '-n', str(elf)], text=True)
    symbols = {p[2]: int(p[0], 16) for line in output.splitlines()
               if len(p := line.split()) == 3}
    args = ['-kernel', str(elf)]
    if boot == 'iso':
        iso_root = tmp / 'iso'
        shutil.copytree(ROOT / 'iso', iso_root)
        shutil.copyfile(elf, iso_root / 'boot/zenc-os.elf')
        # Use the checked-in GRUB configuration, including its menu timeout.
        iso = tmp / 'event-wait.iso'
        run([os.environ.get('GRUB_MKRESCUE', 'grub-mkrescue'), '-o', iso, iso_root])
        args = ['-cdrom', str(iso)]
    return args, symbols


class QMP:
    def __init__(self, path, process):
        self.socket = socket.socket(socket.AF_UNIX)
        deadline = time.monotonic() + 10
        while True:
            try:
                self.socket.connect(str(path))
                break
            except (FileNotFoundError, ConnectionRefusedError):
                if process.poll() is not None or time.monotonic() > deadline:
                    raise RuntimeError('QEMU failed before QMP connection')
                time.sleep(.02)
        self.socket.settimeout(5)
        self.file = self.socket.makefile('rwb', buffering=0)
        json.loads(self.file.readline())
        self.call('qmp_capabilities')

    def call(self, command, **args):
        self.file.write(json.dumps({'execute': command, 'arguments': args}).encode() + b'\n')
        while True:
            response = json.loads(self.file.readline())
            if 'error' in response:
                raise RuntimeError(response['error'])
            if 'return' in response:
                return response['return']

    def close(self):
        self.file.close()
        self.socket.close()


def exercise(qmp, symbols, tmp, evidence, trace):
    sizes = {'_task_states': 4, '_task_current_slot': 4, '_task_wait_channels': 16,
             '_task_dispatch_count': 16, '_task_block_count': 16, '_task_wake_count': 16,
             '_timer_tick_count': 4, '_keyboard_queue_head': 4, '_keyboard_queue_tail': 4,
             '_keyboard_queue_drop_count': 4, '_shell_length': 4, '_shell_buffer': 4096,
             'event_context_result': 4, 'event_worker_progress': 4, 'event_worker_error': 4}
    base = min(symbols[name] for name in sizes)
    size = max(symbols[name] + width for name, width in sizes.items()) - base

    def memory(address, size, name):
        path = tmp / name
        qmp.call('pmemsave', val=address, size=size, filename=str(path))
        return path.read_bytes()

    def snapshot():
        qmp.call('stop')
        try:
            data = memory(base, size, 'ram.bin')
            result = {}
            for name, width in sizes.items():
                offset = symbols[name] - base
                raw = data[offset:offset + width]
                if name == '_shell_buffer':
                    result[name] = raw.split(b'\0', 1)[0].decode('ascii', errors='replace')
                elif name == '_task_states':
                    result[name] = list(raw)
                else:
                    values = list(struct.unpack('<' + 'I' * (width // 4), raw))
                    result[name] = values[0] if width == 4 else values
            return result
        finally:
            qmp.call('cont')

    def wait(predicate, label, seconds=5):
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            current = snapshot()
            if predicate(current):
                return current
            time.sleep(.01)
        raise AssertionError(f'{label}: timeout; snapshot={current}')

    def blocked(s):
        return (s['_task_states'][1] == 4 and s['_task_wait_channels'][1] != 0
                and s['_keyboard_queue_head'] == s['_keyboard_queue_tail'])

    def vga():
        raw = memory(0xb8000, 4000, 'vga.bin')[::2].decode('ascii')
        return raw

    def key(code, expected):
        before = snapshot()
        trace.append({'key': code, 'expected_buffer': expected})
        qmp.call('input-send-event', events=[
            {'type': 'key', 'data': {'down': True, 'key': {'type': 'qcode', 'data': code}}},
            {'type': 'key', 'data': {'down': False, 'key': {'type': 'qcode', 'data': code}}}])
        after = wait(lambda s: blocked(s) and s['_shell_buffer'] == expected
                     and s['_task_block_count'][1] > before['_task_block_count'][1],
                     f'event {len(trace)} {code}')
        assert after['_task_wake_count'][1] == before['_task_wake_count'][1] + 1
        assert after['_task_dispatch_count'][1] == before['_task_dispatch_count'][1] + 1
        assert after['_keyboard_queue_drop_count'] == 0
        assert after['_shell_length'] == len(expected)
        return after

    start = wait(lambda s: blocked(s) and s['event_context_result'] != 0
                 and s['_task_states'][2:] == [0, 0], 'boot/context fixture', 15)
    assert start['event_context_result'] == 1, start
    assert start['event_worker_progress'] == 64 and start['event_worker_error'] == 0, start
    if 'lifecycle_result' not in symbols:
        assert start['_task_block_count'][2] == start['_task_wake_count'][2] == 1, start
    assert 'zos> ' in vga()
    quiet = wait(lambda s: s['_timer_tick_count'] - start['_timer_tick_count'] >= 100,
                 '100 PIT ticks')
    assert quiet['_task_dispatch_count'][1] == start['_task_dispatch_count'][1], quiet
    assert blocked(quiet)
    for round_no in range(1, 101):
        key('a', 'a' * round_no)
        assert 'zos> ' + 'a' * round_no in vga(), f'VGA echo round {round_no}'
    key('backspace', 'a' * 99)
    assert 'zos> ' + 'a' * 99 + ' ' in vga()
    key('ret', '')
    assert 'unknown command' in vga()
    for index, letter in enumerate('clear'):
        key(letter, 'clear'[:index + 1])
    key('ret', '')
    assert vga() == 'zos> ' + ' ' * 1995, 'clear must reset screen and prompt'
    qmp.call('screendump', filename=str(evidence / 'clear.ppm'))
    key('x', 'x')
    key('ret', '')
    screen = vga()
    assert screen[:80].rstrip() == 'zos> x'
    assert screen[80:160].rstrip() == 'unknown command'
    assert screen[160:240].rstrip() == 'zos>'
    qmp.call('screendump', filename=str(evidence / 'unknown-command.ppm'))
    (evidence / 'vga.txt').write_text('\n'.join(screen[i:i+80].rstrip() for i in range(0, 2000, 80)))
    final = snapshot()
    (evidence / 'final-snapshot.json').write_text(json.dumps(final, indent=2))
    assert final['_timer_tick_count'] > start['_timer_tick_count']


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--opt', choices=('-O0', '-O2'),
                        default=os.environ.get('EVENT_WAIT_OPT', '-O0'))
    parser.add_argument('--boot', choices=('direct', 'iso'),
                        default=os.environ.get('EVENT_WAIT_BOOT', 'direct'))
    options = parser.parse_args()
    opt, boot = options.opt, options.boot
    if opt not in ('-O0', '-O2') or boot not in ('direct', 'iso'):
        raise SystemExit('EVENT_WAIT_OPT must be -O0/-O2; EVENT_WAIT_BOOT direct/iso')
    evidence = ROOT / 'build/event-wait' / f'{boot}-{opt[1:]}'
    evidence.mkdir(parents=True, exist_ok=True)
    trace = []
    try:
        with tempfile.TemporaryDirectory(prefix='zos-event-') as directory:
            tmp = Path(directory)
            args, symbols = build(tmp, opt, boot)
            with (evidence / 'qemu.log').open('w') as log:
                process = subprocess.Popen([os.environ.get('QEMU', 'qemu-system-i386'),
                    *args, '-display', 'none', '-serial', 'stdio', '-monitor', 'none',
                    '-no-reboot', '-qmp', f'unix:{tmp}/qmp.sock,server=on,wait=off'],
                    stdout=log, stderr=subprocess.STDOUT)
                qmp = None
                try:
                    qmp = QMP(tmp / 'qmp.sock', process)
                    exercise(qmp, symbols, tmp, evidence, trace)
                finally:
                    if qmp:
                        qmp.close()
                    process.terminate()
                    try:
                        process.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        process.kill()
                        process.wait()
        print(f'event wait QEMU: PASS ({boot}, {opt}, 100 rounds, VGA, context/IF, worker, PIT); {evidence}')
    except subprocess.CalledProcessError as error:
        raise SystemExit(error.stderr.decode(errors='replace')) from error
    finally:
        (evidence / 'events.json').write_text(json.dumps(trace, indent=2))


if __name__ == '__main__':
    main()
