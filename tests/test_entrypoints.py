import os
from pathlib import Path
import signal
import subprocess
import time
import unittest
import test_switching as helpers


class EntryPointTests(unittest.TestCase):
    setUp = helpers.SwitchingTests.setUp
    tool = helpers.SwitchingTests.tool

    def test_downloaded_wrapper_forwards_termination_and_waits_for_rollback(self):
        filename = 'switch-to-realm.sh' if helpers.REALM else 'switch-to-nft.sh'
        wrapper = self.root / filename
        wrapper.write_text((helpers.REPO / filename).read_text())
        child = self.root / 'installer.sh'
        child.write_text('''#!/bin/bash
trap 'echo rollback > "$ROLLBACK_MARKER"; exit 143' TERM
echo started > "$START_MARKER"
while true; do /bin/sleep 0.1; done
''')
        self.tool('id', '#!/bin/bash\necho 0\n')
        self.tool('curl', '''#!/bin/bash
while [ "$#" -gt 0 ]; do
 if [ "$1" = -o ]; then cp "$INSTALLER_FIXTURE" "$2"; exit $?; fi
 shift
done
exit 1
''')
        started, rollback = self.root / 'started', self.root / 'rollback'
        env = dict(self.env, INSTALLER_FIXTURE=str(child), START_MARKER=str(started), ROLLBACK_MARKER=str(rollback))
        process = subprocess.Popen(['bash', str(wrapper)], env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
        try:
            deadline = time.monotonic() + 4
            while not started.exists() and time.monotonic() < deadline:
                if process.poll() is not None:
                    self.fail(process.communicate()[1].decode())
                time.sleep(.02)
            self.assertTrue(started.exists())
            process.terminate()
            try:
                process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                self.fail('Wrapper failed to forward TERM to the transaction child')
            self.assertEqual(process.returncode, 143)
            self.assertTrue(rollback.exists(), 'Wrapper must await installer rollback before exiting')
        finally:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            process.communicate(timeout=3)


if __name__ == '__main__':
    unittest.main()
