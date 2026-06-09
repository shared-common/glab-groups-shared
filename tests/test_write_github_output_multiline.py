import importlib.util
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest import mock


REPO_ROOT = Path(__file__).resolve().parents[1]
SCRIPT = REPO_ROOT / ".github" / "scripts" / "write_github_output_multiline.py"
SPEC = importlib.util.spec_from_file_location("write_github_output_multiline", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class WriteGithubOutputMultilineTests(unittest.TestCase):
    def run_script(self, value: str, *, output_name: str = "ssh-key") -> str:
        with tempfile.TemporaryDirectory() as temp_dir:
            temp_path = Path(temp_dir)
            output_path = temp_path / "github-output.txt"
            value_path = temp_path / "value.txt"
            value_path.write_text(value, encoding="utf-8")
            subprocess.run(
                [
                    "python3",
                    str(SCRIPT),
                    "--output-file",
                    str(output_path),
                    "--name",
                    output_name,
                    "--value-file",
                    str(value_path),
                ],
                check=True,
                cwd=REPO_ROOT,
            )
            return output_path.read_text(encoding="utf-8")

    def test_appends_valid_multiline_output_without_trailing_newline(self) -> None:
        output = self.run_script(
            "-----BEGIN OPENSSH PRIVATE KEY-----\nabc123\n-----END OPENSSH PRIVATE KEY-----"
        )
        lines = output.splitlines()
        self.assertEqual(lines[0].split("<<", 1)[0], "ssh-key")
        delimiter = lines[0].split("<<", 1)[1]
        self.assertEqual(
            lines[1:4],
            [
                "-----BEGIN OPENSSH PRIVATE KEY-----",
                "abc123",
                "-----END OPENSSH PRIVATE KEY-----",
            ],
        )
        self.assertEqual(lines[4], delimiter)

    def test_avoids_delimiter_collisions_in_value(self) -> None:
        first_delimiter = "__GH_OUTPUT_" + ("a" * 64) + "_0__"
        fake_digest = type("FakeDigest", (), {"hexdigest": lambda self: "a" * 64})()
        with mock.patch.object(MODULE.hashlib, "sha256", return_value=fake_digest):
            delimiter = MODULE.choose_delimiter("\n".join([first_delimiter, "payload"]))
        self.assertEqual(delimiter, "__GH_OUTPUT_" + ("a" * 64) + "_1__")

    def test_rejects_invalid_output_name(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            temp_path = Path(temp_dir)
            output_path = temp_path / "github-output.txt"
            value_path = temp_path / "value.txt"
            value_path.write_text("secret\n", encoding="utf-8")
            result = subprocess.run(
                [
                    "python3",
                    str(SCRIPT),
                    "--output-file",
                    str(output_path),
                    "--name",
                    "bad name",
                    "--value-file",
                    str(value_path),
                ],
                cwd=REPO_ROOT,
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("Invalid GitHub output name", result.stderr)


if __name__ == "__main__":
    unittest.main()
