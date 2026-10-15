#!/usr/bin/env python3
"""OpenSIPS translation of the SBC server Logs tab, with a fake MI FIFO call."""
import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('osipslogs', ROOT / 'scripts/opensips-sbc-logs.py')
sbc = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sbc)
BASE = {'managed': True, 'logEnabled': True, 'logLevel': 'notice', 'logRetentionDays': 7,
        'logDebugUntil': None}


class OpensipsLogs(unittest.TestCase):
    def setUp(self):
        self.calls, self.pid = [], '5'
        for patch in [
            mock.patch.object(sbc, 'mi', side_effect=lambda method, params: self.calls.append((method, params))),
            mock.patch.object(sbc, 'main_pid', side_effect=lambda: self.pid),
            mock.patch.object(sbc.core, 'low_disk', return_value=False),
        ]:
            patch.start()
            self.addCleanup(patch.stop)

    def test_levels_use_mi_log_level(self):
        marker = None
        for level, value in (('debug', 4), ('info', 3), ('notice', 2), ('warning', 1), ('error', -1)):
            marker = sbc.apply(dict(BASE, logLevel=level), marker)
            self.assertEqual(self.calls[-1], ('log_level', {'level': value}))

    def test_reapplied_only_after_change_or_restart(self):
        marker = sbc.apply(BASE, None)
        sbc.apply(BASE, marker)
        self.assertEqual(len(self.calls), 1)
        self.pid = '6'
        sbc.apply(BASE, marker)
        self.assertEqual(len(self.calls), 2)

    def test_missing_fifo_is_a_reported_error(self):
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        with mock.patch.object(module, 'MI_FIFO', Path(tempfile.gettempdir()) / 'mnscloud-absent-fifo'):
            with self.assertRaisesRegex(RuntimeError, 'MI FIFO is not available'):
                module.mi('log_level', {'level': 2})

if __name__ == '__main__':
    unittest.main()
