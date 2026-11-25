import os
from pathlib import Path
import subprocess
import tempfile
import time
import signal
import unittest
import test_switching as helpers
REPO = helpers.REPO


class RunnerTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.rules = self.root / 'nat.conf'
        self.config = self.root / 'config.toml'

    def render(self, rules):
        self.rules.write_text(rules)
        env = dict(os.environ, REALM_RULES_FILE=str(self.rules), REALM_CONFIG_FILE=str(self.config), REALM_BIN='/bin/false')
        return subprocess.run(['bash', str(REPO / 'realm-runner.sh'), '--check'], env=env, capture_output=True, text=True, timeout=5)

    def test_shared_rules_render_ipv4_domain_ipv6_and_leading_zero_ports(self):
        result = self.render('# comment\n33345:example.com:33344\n033346:[2001:db8::1]:00443\n33347:2001:db8::2:443\n')
        self.assertEqual(result.returncode, 0, result.stderr)
        config = self.config.read_text()
        self.assertIn('listen = "[::]:33345"', config)
        self.assertIn('remote = "example.com:33344"', config)
        self.assertIn('listen = "[::]:33346"', config)
        self.assertIn('remote = "[2001:db8::1]:443"', config)
        self.assertIn('remote = "[2001:db8::2]:443"', config)

    def test_invalid_rules_do_not_replace_working_config(self):
        for rule in ('SINGLE,33345,33344,example.com', '0:example.com:443', '33345:example.com:65536',
                     '33345:bad"host:443', '33345:example.com:443\n33345:other.example.com:80',
                     '33345:[broken:443', '33345:[:::]:443', '33345:[1:2:3:4:5:6:7]:443', '33345:[12345::]:443', '33345:[::ffff:999.0.0.1]:443', '999999999999999999999:example.com:443'):
            with self.subTest(rule=rule):
                self.config.write_text('working-config')
                result = self.render(rule)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(self.config.read_text(), 'working-config')

    def test_empty_rules_are_valid_idle_configuration(self):
        result = self.render('# empty rules\n')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn('[[endpoints]]', self.config.read_text())

    def test_empty_rules_do_not_launch_crashing_child(self):
        self.rules.write_text('# empty\n')
        marker = self.root / 'child-started'
        binary = self.root / 'realm'
        binary.write_text(f'#!/bin/bash\ntouch {marker}\nexit 1\n')
        binary.chmod(0o755)
        env = dict(os.environ, REALM_RULES_FILE=str(self.rules), REALM_CONFIG_FILE=str(self.config), REALM_BIN=str(binary))
        with subprocess.Popen(['bash', str(REPO / 'realm-runner.sh')], env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE) as process:
            try:
                process.wait(timeout=3)
                self.fail('An idle runner should stay alive waiting for rules')
            except subprocess.TimeoutExpired:
                self.assertFalse(marker.exists())
            finally:
                process.terminate()
                process.communicate(timeout=4)


    def test_reload_recovers_previous_config_after_delayed_child_failure(self):
        self.rules.write_text('33345:good.example.com:33344\n')
        launches = self.root / 'launches'
        binary = self.root / 'realm'
        binary.write_text('''#!/usr/bin/python3
import os, pathlib, sys, time
config=pathlib.Path(sys.argv[2]).read_text()
bad='bad.example.com' in config
with open(os.environ['LAUNCH_LOG'],'a') as log: log.write(('bad' if bad else 'good')+'\\n')
if bad:
 time.sleep(.8)
 sys.exit(1)
while True: time.sleep(.1)
''')
        binary.chmod(0o755)
        env = dict(os.environ, REALM_RULES_FILE=str(self.rules), REALM_CONFIG_FILE=str(self.config), REALM_BIN=str(binary), REALM_CHECK_INTERVAL='.05', LAUNCH_LOG=str(launches))
        process = subprocess.Popen(['bash', str(REPO / 'realm-runner.sh')], env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
        try:
            deadline = time.monotonic() + 15
            while not launches.exists() and time.monotonic() < deadline:
                time.sleep(.02)
            self.assertTrue(launches.exists())
            self.rules.write_text('33345:bad.example.com:33344\n')
            while time.monotonic() < deadline:
                if launches.read_text().splitlines() == ['good','bad','good']:
                    break
                if process.poll() is not None:
                    self.fail(process.communicate()[1].decode())
                time.sleep(.05)
            self.assertEqual(launches.read_text().splitlines(), ['good','bad','good'])
            self.assertIn('good.example.com', self.config.read_text())
            self.assertIsNone(process.poll())
        finally:
            process.terminate()
            try:
                process.communicate(timeout=3)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                process.communicate(timeout=3)


class BinaryTests(unittest.TestCase):
    setUp = helpers.SwitchingTests.setUp
    tool = helpers.SwitchingTests.tool
    shell = helpers.SwitchingTests.shell

    def test_incompatible_gnu_binary_falls_back_to_musl(self):
        import tarfile
        for libc, code in [('gnu', 'echo GLIBC_2.38_not_found >&2; exit 1'), ('musl', 'echo Realm 2.9.6')]:
            binary = self.root / f'realm-{libc}'
            binary.write_text(f'#!/bin/bash\n{code}\n')
            binary.chmod(0o755)
            with tarfile.open(self.root / f'{libc}.tar.gz', 'w:gz') as archive:
                archive.add(binary, arcname='realm')
        self.tool('curl', '''#!/bin/bash
out=''; url=''
while [ "$#" -gt 0 ]; do
 case "$1" in -o) out=$2; shift 2;; http*) url=$1; shift;; *) shift;; esac
done
case "$url" in *musl*) cp "$FIXTURES/musl.tar.gz" "$out";; *gnu*) cp "$FIXTURES/gnu.tar.gz" "$out";; *) exit 1;; esac
''')
        r = self.shell(f'''
WORK_DIR={str(self.root / 'work')!r}
mkdir -p "$WORK_DIR"
REALM_DIR={str(self.root / 'installed')!r}
REALM_BIN="$REALM_DIR/realm"
REALM_VERSION=v2.9.6
latest_realm_version() {{ echo v2.9.6; }}
is_musl_system() {{ return 1; }}
install_realm_binary
"$REALM_STAGED_BINARY" --version
''', FIXTURES=str(self.root))
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn('Realm 2.9.6', r.stdout)
        self.assertFalse((self.root / 'installed' / 'realm').exists(), 'Must stage without overwriting live executable')


class RealmReadinessTests(unittest.TestCase):
    setUp = helpers.SwitchingTests.setUp
    tool = helpers.SwitchingTests.tool
    shell = helpers.SwitchingTests.shell

    def check_listener(self, own_pid):
        import json
        self.initial['realm']['active'] = True
        self.state.write_text(json.dumps(self.initial))
        self.tool('ss', '''#!/bin/bash
printf 'LISTEN users:(("realm",pid=%s,fd=7))\\n' "$SS_LISTENER_PID"
''')
        listener = '$test_child' if own_pid else '1'
        return self.shell(f'''
REALM_BIN=/bin/sleep
REALM_PORTS=33345
/bin/sleep 30 &
test_child=$!
trap 'kill "$test_child"; wait "$test_child" || true' EXIT
export SERVICE_MAIN_PID=$$ SS_LISTENER_PID={listener}
realm_ready
''')

    def test_unrelated_realm_listener_cannot_satisfy_readiness(self):
        self.assertNotEqual(self.check_listener(False).returncode, 0)

    def test_child_listener_satisfies_readiness(self):
        result = self.check_listener(True)
        self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == '__main__':
    unittest.main()
