"""Exercise the actual embedded argument parsers without changing a host OS."""
import pathlib
import re
import subprocess
import sys
import unittest

SOURCE = (pathlib.Path(__file__).resolve().parents[1] / 'bazzite-hibernate.sh').read_text(encoding='utf-8')
PARSERS = re.findall(r"python3 -c '([^']+)'", SOURCE)


class ResumeArguments(unittest.TestCase):
    def run_parser(self, index, *args):
        return subprocess.run([sys.executable, '-c', PARSERS[index], *args], capture_output=True, text=True)

    def test_select_old_values_preserving_quoted_unrelated_options(self):
        result = self.run_parser(0, 'quiet label="two words" resume=UUID=old resume_offset=42 resume=UUID=old')
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout.splitlines(), ['resume=UUID=old', 'resume_offset=42'])

    def test_accept_normal_single_line_output(self):
        result = self.run_parser(1, 'quiet root=UUID=root resume=UUID=new resume_offset=123', 'resume=UUID=new', 'resume_offset=123')
        self.assertEqual(result.returncode, 0)

    def test_reject_missing_wrong_and_duplicate_values(self):
        for value in ['resume=UUID=new', 'resume=UUID=old resume_offset=123', 'resume=UUID=new resume_offset=123 resume_offset=42']:
            with self.subTest(value=value):
                self.assertNotEqual(self.run_parser(1, value, 'resume=UUID=new', 'resume_offset=123').returncode, 0)


if __name__ == '__main__':
    unittest.main()
