#!/usr/bin/env python3
"""Check task lifecycle and fatal exits with real i686 stacks in QEMU.

python3 tests/task_lifecycle_qemu.py --opt=-O2 --boot=iso
Save evidence in build/task-lifecycle/{boot}-{optimization}/.
"""
import argparse
import json
import os
from pathlib import Path
import re
import signal
import struct
import subprocess
import sys
import tempfile
import time

sys.dont_write_bytecode = True
from event_wait_qemu import ROOT, QMP, build, exercise


EXPECTED = {
    'lifecycle_result': 1,
    'lifecycle_error': 0,
    'lifecycle_progress': 100,
    'lifecycle_capacity_result': 1,
    'lifecycle_irq_result': 1,
    'lifecycle_boundary_result': 1,
    'lifecycle_handoff_error': 0,
}
COUNTERS = ('_timer_tick_count', 'zos_interrupt_count')
DIAGNOSTICS = {
    1: 'task exit: invalid context',
    2: 'task exit: no ready fallback',
}
CASE_TIMEOUT = 120


def save_json(path, value):
    path.write_text(json.dumps(value, indent=2) + '\n')


def snapshot(qmp, symbols, tmp, registers=False):
    names = [*EXPECTED, 'lifecycle_handoff_count', *COUNTERS]
    names += [name for name in ('_task_created_count', '_task_live_count',
                               '_task_current_slot', '_task_pending_reap')
              if name in symbols]
    base = min(symbols[name] for name in names)
    size = max(symbols[name] + 4 for name in names) - base
    path = tmp / 'lifecycle-ram.bin'
    qmp.call('stop')
    try:
        qmp.call('pmemsave', val=base, size=size, filename=str(path))
        data = path.read_bytes()
        result = {name: struct.unpack_from('<I', data, symbols[name] - base)[0]
                  for name in names}
        if registers:
            result['registers'] = qmp.call('human-monitor-command',
                                           **{'command-line': 'info registers'})
        return result
    finally:
        qmp.call('cont')


def wait_lifecycle(qmp, symbols, tmp, evidence, trace, log_path):
    deadline = time.monotonic() + 15
    current = {}
    while time.monotonic() < deadline:
        # GRUB can use these addresses before it loads and initializes the kernel.
        if 'shell task: running\n' not in log_path.read_text(errors='replace'):
            time.sleep(.01)
            continue
        current = snapshot(qmp, symbols, tmp)
        save_json(evidence / 'lifecycle-snapshot.json', current)
        if current['lifecycle_error'] != 0 or current['lifecycle_result'] != 0:
            trace.append({'phase': 'lifecycle', 'snapshot': current})
            assert all(current[name] == expected for name, expected in EXPECTED.items()), current
            assert current['lifecycle_handoff_count'] > 300, current
            return
        time.sleep(.01)
    trace.append({'phase': 'lifecycle-timeout', 'snapshot': current})
    raise AssertionError(f'Lifecycle fixture did not complete within 15 seconds: {current}')


def parse_halt_registers(registers):
    flags = re.search(r'\bEFL=([0-9a-fA-F]+)\b', registers)
    halted = re.search(r'\bHLT=([01])\b', registers)
    assert flags and halted, f'QEMU register report has no EFL or HLT field: {registers}'
    result = {'eflags': int(flags[1], 16), 'halted': int(halted[1])}
    assert result['eflags'] & 0x200 == 0, f'Fatal exit left IRQ enabled: {result}'
    assert result['halted'] == 1, f'Fatal exit did not halt the CPU: {result}'
    return result


def verify_stopped_counters(first, second):
    for name in COUNTERS:
        assert first[name] == second[name], f'Fatal exit did not stop {name}: {first} -> {second}'


def verify_diagnostic(text, expected):
    assert text.count(expected) == 1, f'Expected one diagnostic: {expected!r}'
    assert text.count('task exit:') == 1, 'Fatal exit emitted more than one task diagnostic'


def exercise_fatal(qmp, symbols, tmp, evidence, trace, log_path, mode, process):
    expected = DIAGNOSTICS[mode]
    deadline = time.monotonic() + 15
    while time.monotonic() < deadline:
        text = log_path.read_text(errors='replace')
        if re.search(r'^task exit:.*\n', text, re.MULTILINE):
            verify_diagnostic(text, expected)
            break
        assert process.poll() is None, f'QEMU exited before the fatal diagnostic: {text}'
        time.sleep(.01)
    else:
        raise AssertionError(f'Fatal diagnostic did not arrive within 15 seconds: {expected}')

    # Snapshot resumes QEMU before this interval. A paused VM cannot prove that IRQ stopped.
    first = snapshot(qmp, symbols, tmp, registers=True)
    save_json(evidence / 'fatal-first-snapshot.json', first)
    (evidence / 'fatal-first-registers.txt').write_text(first['registers'])
    trace.append({'phase': 'fatal-first', 'snapshot': first})
    parse_halt_registers(first['registers'])
    time.sleep(.1)
    second = snapshot(qmp, symbols, tmp, registers=True)
    save_json(evidence / 'fatal-second-snapshot.json', second)
    (evidence / 'fatal-second-registers.txt').write_text(second['registers'])
    trace.append({'phase': 'fatal-second', 'snapshot': second})
    parse_halt_registers(second['registers'])
    verify_stopped_counters(first, second)
    verify_diagnostic(log_path.read_text(errors='replace'), expected)
    assert process.poll() is None, 'QEMU exited during the fatal halt check'


def timeout_handler(signum, frame):
    raise TimeoutError(f'QEMU acceptance case exceeded {CASE_TIMEOUT} seconds')


def run_case(opt, boot, evidence, mode=0):
    evidence.mkdir(parents=True, exist_ok=True)
    trace = []
    result = {'opt': opt, 'boot': boot, 'panic': mode, 'passed': False}
    process = qmp = None
    previous_handler = signal.signal(signal.SIGALRM, timeout_handler)
    signal.alarm(CASE_TIMEOUT)
    try:
        with tempfile.TemporaryDirectory(prefix='zos-lifecycle-qemu-') as directory:
            tmp = Path(directory)
            args, symbols = build(tmp, opt, boot,
                                  extra_sources=[ROOT / 'tests/task_lifecycle_fixture.c',
                                                 ROOT / 'tests/task_lifecycle_context.S'],
                                  extra_wrappers=['task_idle', 'timer_handle_irq',
                                                  '_task_reap_switched'],
                                  extra_defines=[f'ZOS_LIFECYCLE_PANIC={mode}'] if mode else [])
            log_path = evidence / 'qemu.log'
            with log_path.open('w') as log:
                process = subprocess.Popen([
                    os.environ.get('QEMU', 'qemu-system-i386'), *args,
                    '-display', 'none', '-serial', 'stdio', '-monitor', 'none',
                    '-no-reboot', '-qmp', f'unix:{tmp}/qmp.sock,server=on,wait=off'],
                    stdout=log, stderr=subprocess.STDOUT)
                try:
                    qmp = QMP(tmp / 'qmp.sock', process)
                    if mode:
                        exercise_fatal(qmp, symbols, tmp, evidence, trace, log_path, mode, process)
                    else:
                        wait_lifecycle(qmp, symbols, tmp, evidence, trace, log_path)
                        exercise(qmp, symbols, tmp, evidence, trace)
                    result['passed'] = True
                finally:
                    try:
                        if qmp:
                            qmp.close()
                    finally:
                        process.terminate()
                        try:
                            process.wait(timeout=5)
                        except subprocess.TimeoutExpired:
                            process.kill()
                            process.wait(timeout=5)
    except Exception as error:
        result['passed'] = False
        result['error'] = f'{type(error).__name__}: {error}'
        if isinstance(error, subprocess.CalledProcessError):
            output = (error.stdout or b'') + (error.stderr or b'')
            (evidence / 'build.log').write_bytes(output)
            result['error'] += '\n' + output.decode(errors='replace')
    finally:
        signal.alarm(0)
        signal.signal(signal.SIGALRM, previous_handler)
        save_json(evidence / 'events.json', trace)
        save_json(evidence / 'result.json', result)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--opt', choices=('-O0', '-O2'),
                        default=os.environ.get('TASK_LIFECYCLE_OPT', '-O0'))
    parser.add_argument('--boot', choices=('direct', 'iso'),
                        default=os.environ.get('TASK_LIFECYCLE_BOOT', 'direct'))
    options = parser.parse_args()
    evidence = ROOT / 'build/task-lifecycle' / f'{options.boot}-{options.opt[1:]}'
    results = []
    for mode in (0, 1, 2):
        case_evidence = evidence if mode == 0 else evidence / f'panic-{mode}'
        result = run_case(options.opt, options.boot, case_evidence, mode)
        results.append(result)
        label = 'lifecycle and event regression' if mode == 0 else f'fatal exit {mode}'
        status = 'PASS' if result['passed'] else 'FAIL'
        print(f'task lifecycle QEMU: {status} ({options.boot}, {options.opt}, {label}). {case_evidence}',
              flush=True)
        if not result['passed']:
            print(result['error'], flush=True)
    save_json(evidence / 'results.json', results)
    if not all(result['passed'] for result in results):
        raise SystemExit(1)


if __name__ == '__main__':
    main()
