"""Regression checks run against production shell functions; no phone is modified."""
import hashlib
import importlib.util
import os
import shutil
import subprocess
import tempfile
import unittest
import xml.etree.ElementTree as ET
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
COMMON = REPO/'code/diagnostics/phh_common.sh'
WATCHDOG = REPO/'code/diagnostics/phh_watchdog.sh'
CARRIER = REPO/'code/module/carrier-config.sh'
BASH = os.environ.get('BASH_EXE') or (
    r'C:\Program Files\Git\bin\bash.exe' if os.name == 'nt' else shutil.which('bash')
)


def shell(body, *args, env=None, check=True, argv0='test'):
    merged = os.environ.copy()
    merged.update(env or {})
    result = subprocess.run(
        [BASH, '--noprofile', '--norc', '-c', body, argv0,
         *[Path(a).as_posix() if isinstance(a, Path) else str(a) for a in args]],
        capture_output=True, text=True, env=merged, timeout=15,
    )
    if check and result.returncode:
        raise AssertionError(f'{result.returncode}: {result.stdout}\n{result.stderr}')
    return result


class RuntimeTests(unittest.TestCase):
    def test_every_sim_and_unknown_state(self):
        fixtures = {
            'mCallState=0\nmCallState=0': '0',
            'mCallState=0\nmCallState=1': '1',
            'mCallState=0\nmCallState=2': '1',
            'mCallState=2\nmCallState=0': '1',
            '': 'unknown', 'mCallState=bad': 'unknown',
        }
        for raw, expected in fixtures.items():
            with self.subTest(raw=raw):
                result = shell('. "$1"; dumpsys() { printf "%s\\n" "$REGISTRY"; }; phh_incall',
                               COMMON, env={'REGISTRY': raw})
                self.assertEqual(result.stdout.strip(), expected)

    def test_old_grant_keeps_event_timestamp(self):
        result = shell('''. "$1"
logcat() { printf '%s\n' '  15000.123 123 456 D PHH SipHandler: registration granted for 3590s'; }
phh_grant 123
phh_grant 123
''', COMMON)
        self.assertEqual(result.stdout.splitlines(), ['15000 3590', '15000 3590'])

    def test_dangling_spi_not_total_policy_count(self):
        result = shell('''. "$1"
ip() {
  case "$2" in
    state) printf '%s\n' 'spi 0x01' 'spi 0x02' ;;
    policy) printf '%s\n' 'spi 0x01' 'spi 0x01' 'spi 0x02' 'spi 0x03' ;;
  esac
}
phh_dangling
''', COMMON)
        self.assertEqual(result.stdout.strip(), '1')

    def test_watchdog_decisions_with_mocked_android_services(self):
        # Actual daemon, one loop. All Android services and sleep are mocks;
        # logs, lock and timestamp stay inside the temporary directory.
        scenarios = [
            ('fresh', 'mCallState=0\nmCallState=0', '19900', 'yes', False),
            ('stale', 'mCallState=0\nmCallState=0', '15000', 'yes', True),
            ('second-sim', 'mCallState=0\nmCallState=2', '15000', 'yes', False),
            ('unknown', '', '15000', 'yes', False),
            ('offline', 'mCallState=0\nmCallState=0', '15000', 'no', False),
        ]
        for name, state, event, wifi, expect_recovery in scenarios:
            with self.subTest(name=name), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp)
                (root/'phh_health.sh').write_text("printf '%s\\n' 'OK incall=0'\n", newline='\n')
                body = '''
date() { printf '%s\n' 20000; }
pidof() { printf '%s\n' 123; }
dumpsys() { printf '%s\n' "$REGISTRY"; }
ip() { [ "$WIFI" = yes ] && printf '%s\n' 'wlan0 inet 192.0.2.1'; }
logcat() { printf '%s.123 123 456 D PHH SipHandler: registration granted for 3590s\n' "$EVENT"; }
flock() { return 0; }
am() { printf '%s\n' "$*" >> "$PHH_RUNTIME_DIR/actions"; }
sleep() { if [ "$1" = 120 ]; then exit 0; fi; }
. "$1"
'''
                shell(body, WATCHDOG, argv0=WATCHDOG.as_posix(), env={
                    'PHH_RUNTIME_DIR': root.as_posix(), 'REGISTRY': state,
                    'EVENT': event, 'WIFI': wifi,
                })
                actions = root/'actions'
                self.assertEqual(actions.exists(), expect_recovery)
                if actions.exists():
                    self.assertEqual(actions.read_text().strip(), 'force-stop me.phh.ims')
                self.assertEqual((root/'phh_last_grant').read_text().strip(), event)


class CarrierTests(unittest.TestCase):
    def test_repair_values_pairs_duplicates_and_idempotence(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            original, output, again = root/'input.xml', root/'output.xml', root/'again.xml'
            original.write_text('<bundle>\n<string name="kept">keep-me</string>\n</bundle>\n')
            shell('. "$1"; cc_render "$2" "$3"', CARRIER, original, output)
            valid = output.read_text()
            tree = ET.fromstring(valid)
            self.assertEqual(len(tree.findall('string')), 8)
            self.assertIn('keep-me', valid)
            key = 'carrier_network_service_wlan_class_override_string'
            line = next(s for s in valid.splitlines() if f'name="{key}"' in s)
            for mutated in (valid.replace(line, ''), valid.replace('com.voxi.minqns.MinQnsService', 'stock.Bad'),
                            valid.replace(line, line+line)):
                original.write_text(mutated)
                self.assertNotEqual(shell('. "$1"; cc_valid "$2"', CARRIER, original, check=False).returncode, 0)
                shell('. "$1"; cc_render "$2" "$3"', CARRIER, original, output)
                repaired = ET.fromstring(output.read_text())
                self.assertEqual([(s.attrib, s.text) for s in repaired], [(s.attrib, s.text) for s in tree])
            shell('. "$1"; cc_render "$2" "$3"', CARRIER, output, again)
            self.assertEqual(output.read_bytes(), again.read_bytes())

    def test_unsupported_bundle_refused(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            for raw in ('<broken>', '<bundle>\n</bundle>\n<bundle>\n</bundle>'):
                (root/'input').write_text(raw)
                result = shell('. "$1"; cc_render "$2" "$3"', CARRIER, root/'input', root/'output', check=False)
                self.assertNotEqual(result.returncode, 0)


    def test_restore_already_injected_backup(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            original, injected, restored = root/'input', root/'injected', root/'restored'
            original.write_text('<bundle>\n<string name="kept">keep-me</string>\n</bundle>\n')
            shell('. "$1"; cc_render "$2" "$3"', CARRIER, original, injected)
            shell('. "$1"; cc_remove_ours "$2" "$3"', CARRIER, injected, restored)
            tree = ET.fromstring(restored.read_text())
            self.assertEqual([(s.attrib, s.text) for s in tree], [({'name': 'kept'}, 'keep-me')])
            injected.write_text(injected.read_text().replace('>me.phh.ims<', '>stock.ims<'))
            shell('. "$1"; cc_remove_ours "$2" "$3"', CARRIER, injected, restored)
            tree = ET.fromstring(restored.read_text())
            self.assertIn('stock.ims', [s.text for s in tree])


class PackageTests(unittest.TestCase):
    def test_payload_matches_deployed_binaries(self):
        spec = importlib.util.spec_from_file_location('pack', REPO/'code/build/package_module.py')
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        files = module.payload()
        expected = {
            'IwlanAosp': 'b7ea43641071cdb87ad65cb016503f071e3f9ecf1b25d60b4676af8ccc52ced9',
            'PhhIms': '4a2d9755c86f4a2049b6f9f85aae0ff7cf33b6ed645bc3c866d022e7d53fcfa1',
            'MinQns': '432948e7e4d8415b9ee849094da103e91b5a7a26c0040bb1d0501095351e5c43',
        }
        for name, digest in expected.items():
            data = files[f'system/system_ext/priv-app/{name}/{name}.apk']
            self.assertEqual(hashlib.sha256(data).hexdigest(), digest)
        self.assertIn('tools/phh_common.sh', files)
        self.assertIn('carrier-config.sh', files)


if __name__ == '__main__':
    unittest.main(verbosity=2)
