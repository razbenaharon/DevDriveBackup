"""Checks Build-BackupReport.py on made-up data. Standard library only; needs no Chart.js and no drive.

Run: python ./Test-BackupToolsReport.py
"""
import csv
import importlib.util
import json
import pathlib
import tempfile
import unittest

HERE = pathlib.Path(__file__).resolve().parent


def load():
    spec = importlib.util.spec_from_file_location('build_backup_report', HERE / 'Build-BackupReport.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)  # must not start building a report: that is main()'s job
    return module


class ReportTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.report = load()

    def test_computer_with_two_processors(self):
        # Get-BackupHardware.ps1 writes one object for one processor and a list for several.
        self.assertEqual(self.report.cpu_name({'Name': 'CPU A'}), 'CPU A')
        self.assertEqual(self.report.cpu_name([{'Name': 'CPU A'}, {'Name': 'CPU A'}]), '2 × CPU A')
        self.assertEqual(self.report.cpu_name([{'Name': 'CPU A'}, {'Name': 'CPU B'}]), 'CPU A, CPU B')

    def test_text_cannot_end_or_derail_the_script(self):
        # "<!--<script" inside a script element makes the browser ignore the closing tag after it.
        data = {'notes': ['<!--<script>', '</script><script>alert(1)</script>', 'a < b']}
        embedded = self.report.embed(data)
        self.assertNotIn('<', embedded)
        self.assertEqual(json.loads(embedded), data)

    def test_link_that_could_not_be_measured(self):
        self.assertEqual(self.report.link_text({'Speed': 'SuperSpeed (5 Gbit/s+)'}), 'SuperSpeed (5 Gbit/s+)')
        text = self.report.link_text({'Error': 'Not a USB device', 'BusType': 'NVMe'})
        self.assertIn('not measured', text)
        self.assertIn('Not a USB device', text)
        self.assertNotIn('undefined', text)

    def test_only_temporary_folders_are_marked_temporary(self):
        for name in ('Temp', 'temp', 'tmp', 'Temp\\downloads', 'temp-old', 'tmp_1'):
            self.assertTrue(self.report.is_temporary(name), name)
        for name in ('Templates', 'Temperature-logs', 'Projects\\temp', 'tmpl', 'Projects'):
            self.assertFalse(self.report.is_temporary(name), name)

    def test_chart_library_must_match_its_checksum(self):
        with self.assertRaises(ValueError):
            self.report.check_bundle(b'window.Chart=function(){};')

    def test_whole_report_from_files(self):
        with tempfile.TemporaryDirectory() as folder:
            audit = pathlib.Path(folder)
            with (audit / 'folder-summary.csv').open('w', encoding='utf-8-sig', newline='') as handle:
                writer = csv.writer(handle)
                writer.writerow(['Path', 'Bytes', 'Files', 'Directories', 'CacheBytes', 'CacheFiles', 'GitBytes', 'DataBytes', 'SecretBytes', 'Errors', 'Links', 'LatestUtc'])
                for path, size in (('(all)', 3100), ('Projects', 2000), ("Tom & Jerry's", 1000), ('Templates', 100), ('Temp', 5)):
                    writer.writerow([path, size, 3, 1, 0, 0, 0, 0, 0, 0, 0, '2026-01-01T00:00:00.0000000'])
            (audit / 'disk-benchmark.json').write_text(json.dumps({
                'Utc': '2026-11-12T10:00:00.1234567Z', 'Disk': 'Disk </script><img src=x onerror=alert(1)>',
                'Benchmark': {'Bytes': 536870912, 'BlockBytes': 4194304, 'WriteMBps': 100.0, 'ReadMBps': 120.0}}), encoding='utf-8')
            (audit / 'usb-speed.json').write_text(json.dumps({'Error': 'Not a USB device', 'BusType': 'NVMe'}), encoding='utf-8')
            (audit / 'hardware.json').write_text(json.dumps({'CPU': [{'Name': 'CPU A'}, {'Name': 'CPU A'}], 'System': {'TotalPhysicalMemory': 2 ** 35}}), encoding='utf-8')
            (audit / 'config.json').write_text(json.dumps({'Choices': [{'Path': 'Projects', 'Mode': 'Both', 'Reason': 'Source'}], 'ReportNotes': ['<!--<script>']}), encoding='utf-8')
            data = self.report.build(audit, audit / 'hardware.json', audit / 'config.json')
            page = self.report.render(data, 'window.Chart=function(){};')
        self.assertEqual(data['cpu'], '2 × CPU A')
        self.assertEqual(data['ram'], 32)
        self.assertIn('not measured', data['link'])
        self.assertEqual({row['Path']: row['Temp'] for row in data['rows']}, {'(all)': False, 'Projects': False, "Tom & Jerry's": False, 'Templates': False, 'Temp': True})
        self.assertEqual(page.count('</script>'), 2)  # the chart library and the report's own script
        self.assertNotIn('<!--<script', page)
        self.assertNotIn('<img', page)  # the drive name's markup stays text
        self.assertNotIn('__DATA__', page)


if __name__ == '__main__':
    unittest.main(verbosity=2)
