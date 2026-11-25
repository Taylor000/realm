"""Run real installer functions; replace only host service/package boundaries."""
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[1]
REALM = (REPO / "realm-runner.sh").exists()

def definitions(path):
    if not path.exists():
        return ""
    return "\n".join(re.findall(r"(?ms)^\w+\(\)\s*\{.*?^\}", path.read_text()))

class SwitchingTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.state = self.root / "state.json"
        self.initial = {"nat": {"active": True, "enabled": True},
                        "realm": {"active": False, "enabled": False}}
        self.state.write_text(json.dumps(self.initial))
        self.tool("systemctl", '''#!/usr/bin/python3
import json, os, sys
from pathlib import Path
p=Path(os.environ['SERVICE_STATE']); s=json.loads(p.read_text())
a=sys.argv[1:]
if os.environ.get('SYSTEMCTL_LOG'):
 with open(os.environ['SYSTEMCTL_LOG'],'a') as trace: trace.write(' '.join(a)+'\\n')
op=a[0]; name=next((x.removesuffix('.service') for x in a[1:] if x.removesuffix('.service') in s), '')
if op in ('daemon-reload','reset-failed'): sys.exit(0)
if not name: sys.exit(1)
v=s[name]
if op=='is-active':
 print('active' if v['active'] else 'inactive'); sys.exit(0 if v['active'] else 3)
if op=='is-enabled':
 if name=='realm' and os.environ.get('ABSENT_TARGET_UNIT') and not Path(os.environ['ABSENT_TARGET_UNIT']).exists():
  print('not-found'); sys.exit(1)
 print(v.get('mode', 'enabled' if v['enabled'] else 'disabled')); sys.exit(0 if v['enabled'] else 1)
if op=='show':
 if os.environ.get('UNSTABLE_PID') and v['active']:
  c=Path(os.environ['SERVICE_STATE']+'.counter'); n=int(c.read_text())+1 if c.exists() else 1; c.write_text(str(n)); v['pid']=n
 prop=a[a.index('--property')+1] if '--property' in a else next((x.split('=',1)[1] for x in a if x.startswith('--property=')), '')
 vals={'MainPID':str(os.environ.get('SERVICE_MAIN_PID', v.get('pid',101)) if v['active'] else 0),'NRestarts':'0','LoadState':'loaded','ActiveState':'active' if v['active'] else 'inactive'}
 print(vals.get(prop,'')); sys.exit(0)
if op in ('start','restart'):
 if os.environ.get('FAIL_START')==name: sys.exit(1)
 v['active']=True
elif op=='stop':
 v['active']=False
 if name=='nat' and os.environ.get('NFT_KERNEL'): Path(os.environ['NFT_KERNEL']).write_text('')
elif op=='enable':
 v['enabled']=True
 if 'mode' in v or '--runtime' in a: v['mode']='enabled-runtime' if '--runtime' in a else 'enabled'
 if name=='realm' and os.environ.get('PERSISTENT_LINK') and '--runtime' not in a: Path(os.environ['PERSISTENT_LINK']).touch()
elif op=='disable':
 if name=='realm' and os.environ.get('ABSENT_TARGET_UNIT') and not Path(os.environ['ABSENT_TARGET_UNIT']).exists(): sys.exit(1)
 v['enabled']=False
 if 'mode' in v: v['mode']='disabled'
 if name=='realm' and os.environ.get('PERSISTENT_LINK'): Path(os.environ['PERSISTENT_LINK']).unlink(missing_ok=True)
else: sys.exit(1)
p.write_text(json.dumps(s))
''')
        self.tool("nft", '#!/bin/bash\nif [ "$*" = "list tables" ]; then exit 0; fi\nexit 1\n')
        self.tool("journalctl", "#!/bin/bash\nexit 0\n")
        self.tool("sleep", "#!/bin/bash\nexit 0\n")
        self.tool("apt-get", '#!/bin/bash\necho "$*" >> "$APT_LOG"\nexit "${APT_EXIT:-0}"\n')
        self.env = dict(os.environ, PATH=f"{self.bin}:{os.environ['PATH']}",
                        SERVICE_STATE=str(self.state), APT_LOG=str(self.root / "apt.log"), SYSTEMCTL_LOG=str(self.root / "systemctl.log"))

    def tool(self, name, body):
        p = self.bin / name
        p.write_text(body)
        p.chmod(0o755)

    def shell(self, code, **env):
        prelude = definitions(REPO / "backend-common.sh") + "\n" + definitions(REPO / "setup.sh")
        return subprocess.run(["bash", "-c", "set -Eeuo pipefail\n" + prelude + "\n" + code],
                              env=dict(self.env, **env), text=True, capture_output=True, timeout=15)

    def transaction(self, code, target="realm", previous="nat", **env):
        work = self.root / "work"
        work.mkdir()
        return self.shell(f'''
WORK_DIR={str(work)!r}
BACKUP_BASE={str(self.root / 'backups')!r}
FORWARD_LOCK_FILE={str(self.root / 'switch.lock')!r}
trap 'finish_install $?' EXIT
begin_switch {target} {previous}
{code}
''', **env)

    def test_installed_dependencies_do_not_require_apt(self):
        name = "install_dependencies" if REALM else "prepare_system"
        r = self.shell(f"command_exists() {{ return 0; }}\n{name}", APT_EXIT="100")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertFalse((self.root / "apt.log").exists(), r.stdout)

    def test_failed_dependency_install_aborts(self):
        name = "install_dependencies" if REALM else "prepare_system"
        r = self.shell(f'''command_exists() {{ [ "$1" != curl ]; }}
{name}
echo SHOULD_NOT_CONTINUE
''', APT_EXIT="100")
        self.assertNotEqual(r.returncode, 0)
        self.assertNotIn("SHOULD_NOT_CONTINUE", r.stdout)
        self.assertEqual(json.loads(self.state.read_text()), self.initial)

    def test_failure_restores_file_and_service_states(self):
        for target, previous in (("realm", "nat"), ("nat", "realm")):
            with self.subTest(target=target):
                self.state.write_text(json.dumps({target: dict(active=False, enabled=False),
                                                  previous: dict(active=True, enabled=True)}))
                f = self.root / f"{target}.bin"
                f.write_text("old-binary")
                work = self.root / "work"
                if work.exists():
                    work.rmdir()
                r = self.transaction(f'''snapshot_file {str(f)!r}
FILES_CHANGED=1
printf broken > {str(f)!r}
backend_ready() {{ return 1; }}
activate_backend backend_ready
''', target, previous)
                self.assertNotEqual(r.returncode, 0)
                self.assertIn('Restoring previous', r.stderr)
                self.assertEqual(f.read_text(), "old-binary", r.stderr)
                state = json.loads(self.state.read_text())
                self.assertTrue(state[previous]["active"])
                self.assertTrue(state[previous]["enabled"])
                self.assertFalse(state[target]["active"])
                self.assertFalse(state[target]["enabled"])

    def test_rollback_preserves_disabled_but_running_previous(self):
        self.initial["nat"]["enabled"] = False
        self.state.write_text(json.dumps(self.initial))
        r = self.transaction("backend_ready() { return 1; }; activate_backend backend_ready")
        self.assertNotEqual(r.returncode, 0)
        self.assertEqual(json.loads(self.state.read_text()), self.initial, r.stderr)

    def test_rollback_restores_existing_target_installation(self):
        self.initial = {"nat": dict(active=False, enabled=False),
                        "realm": dict(active=True, enabled=True)}
        self.state.write_text(json.dumps(self.initial))
        r = self.transaction("backend_ready() { return 1; }; activate_backend backend_ready")
        self.assertNotEqual(r.returncode, 0)
        self.assertEqual(json.loads(self.state.read_text()), self.initial, r.stderr)

    def test_failed_start_recovers_previous_backend(self):
        r = self.transaction("backend_ready() { return 0; }; activate_backend backend_ready", FAIL_START="realm")
        self.assertNotEqual(r.returncode, 0)
        self.assertEqual(json.loads(self.state.read_text()), self.initial, r.stderr)

    def test_success_commits_exclusive_backend(self):
        r = self.transaction("backend_ready() { return 0; }; activate_backend backend_ready; commit_switch")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(json.loads(self.state.read_text()),
                         {"nat": dict(active=False, enabled=False),
                          "realm": dict(active=True, enabled=True)})

    def test_signal_rolls_back(self):
        r = self.transaction('''trap 'exit 143' TERM
SWITCH_STARTED=1
systemctl stop nat
kill -TERM $$
''')
        self.assertEqual(r.returncode, 143, r.stderr)
        self.assertEqual(json.loads(self.state.read_text()), self.initial)

    def test_overlapping_switch_is_rejected(self):
        r = self.transaction('''(
WORK_DIR=$(mktemp -d)
begin_switch nat realm
)''')
        self.assertNotEqual(r.returncode, 0)
        self.assertEqual(json.loads(self.state.read_text()), self.initial)

    def test_changing_process_is_not_reported_as_healthy(self):
        r = self.transaction("backend_ready() { return 0; }; activate_backend backend_ready; commit_switch", UNSTABLE_PID="1")
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("Restoring previous", r.stderr)
        self.assertEqual(json.loads(self.state.read_text()), self.initial)

    def test_rollback_removes_new_files_and_preserves_symlinks(self):
        original = self.root / "original"
        original.write_text("keep")
        link = self.root / "link"
        link.symlink_to(original)
        new = self.root / "new-unit"
        r = self.transaction(f"""snapshot_file {str(link)!r}
snapshot_file {str(new)!r}
FILES_CHANGED=1
rm {str(link)!r}
echo replacement > {str(link)!r}
echo new > {str(new)!r}
false
""")
        self.assertNotEqual(r.returncode, 0)
        self.assertTrue(link.is_symlink(), r.stderr)
        self.assertEqual(original.read_text(), "keep")
        self.assertFalse(new.exists())

    def test_failed_first_install_does_not_report_incomplete_rollback(self):
        unit = self.root / "new.service"
        r = self.transaction(f"""snapshot_file {str(unit)!r}
FILES_CHANGED=1
echo unit > {str(unit)!r}
backend_ready() {{ return 1; }}
activate_backend backend_ready
""", ABSENT_TARGET_UNIT=str(unit))
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("Restoring previous", r.stderr)
        self.assertNotIn("rollback was incomplete", r.stderr)
        self.assertFalse(unit.exists())
        self.assertEqual(json.loads(self.state.read_text()), self.initial)

    def test_failed_snapshot_does_not_break_existing_target(self):
        self.initial = {"nat": dict(active=False, enabled=False), "realm": dict(active=True, enabled=True)}
        self.state.write_text(json.dumps(self.initial))
        first, second = self.root / "first", self.root / "second"
        first.write_text("original-one")
        second.write_text("original-two")
        self.tool("cp", '#!/bin/bash\nfor arg in "$@"; do [ "$arg" != "$FAIL_COPY" ] || exit 1; done\nexec /bin/cp "$@"\n')
        r = self.transaction(f"""snapshot_file {str(first)!r}
FILES_CHANGED=1
echo broken > {str(first)!r}
snapshot_file {str(second)!r}
""", FAIL_COPY=str(second))
        self.assertNotEqual(r.returncode, 0)
        self.assertEqual(first.read_text(), "original-one")
        self.assertEqual(second.read_text(), "original-two")
        self.assertEqual(json.loads(self.state.read_text()), self.initial, r.stderr)
        self.assertNotIn("unbound variable", r.stderr)

    def test_runtime_enablement_does_not_become_persistent_on_failure(self):
        self.initial["realm"] = dict(active=False, enabled=True, mode="enabled-runtime")
        self.state.write_text(json.dumps(self.initial))
        marker = self.root / "persistent-link"
        r = self.transaction("backend_ready() { return 1; }; activate_backend backend_ready", PERSISTENT_LINK=str(marker))
        self.assertNotEqual(r.returncode, 0)
        self.assertEqual(json.loads(self.state.read_text()), self.initial, r.stderr)
        self.assertFalse(marker.exists(), "Persistent enablement introduced by switching must be removed")

    def test_active_masked_previous_service_is_rejected_before_mutation(self):
        self.initial["nat"]["mode"] = "masked"
        self.state.write_text(json.dumps(self.initial))
        r = self.transaction("backend_ready() { return 0; }; activate_backend backend_ready; commit_switch")
        self.assertNotEqual(r.returncode, 0)
        self.assertEqual(json.loads(self.state.read_text()), self.initial, r.stderr)

    def test_orphaned_nft_rules_are_restored_after_failed_switch(self):
        self.initial = {"nat": dict(active=False, enabled=False), "realm": dict(active=True, enabled=True)}
        self.state.write_text(json.dumps(self.initial))
        kernel = self.root / "kernel.nft"
        original = "table ip self-nat { chain PREROUTING { tcp dport 33345 dnat to 192.0.2.1:33344; } }\n"
        kernel.write_text(original)
        self.tool("nft", '''#!/bin/bash
if [ "$1" = -n ]; then shift; fi
case "$*" in
 "list tables") [ ! -s "$NFT_KERNEL" ] || echo 'table ip self-nat'; exit 0;;
 "list table ip self-nat") [ -s "$NFT_KERNEL" ] || exit 1; cat "$NFT_KERNEL";;
 "delete table ip self-nat") : > "$NFT_KERNEL";;
 *) if [ "$1" = -f ]; then cat "$2" > "$NFT_KERNEL"; else exit 1; fi;;
esac
''')
        r = self.transaction('''backend_ready() { echo broken > "$NFT_KERNEL"; return 1; }
activate_backend backend_ready
''', target="nat", previous="realm", NFT_KERNEL=str(kernel))
        self.assertNotEqual(r.returncode, 0)
        self.assertEqual(kernel.read_text(), original, r.stderr)
        self.assertEqual(json.loads(self.state.read_text()), self.initial)

    def test_preflight_snapshot_failure_does_not_stop_active_target(self):
        self.initial = {"nat": dict(active=False, enabled=False), "realm": dict(active=True, enabled=True)}
        self.state.write_text(json.dumps(self.initial))
        file = self.root / "existing"
        file.write_text("unchanged")
        self.tool("cp", "#!/bin/bash\nexit 1\n")
        r = self.transaction(f"snapshot_file {str(file)!r}")
        self.assertNotEqual(r.returncode, 0)
        self.assertEqual(file.read_text(), "unchanged")
        self.assertEqual(json.loads(self.state.read_text()), self.initial)
        self.assertNotIn("stop ", (self.root / "systemctl.log").read_text())

if __name__ == "__main__":
    unittest.main()
