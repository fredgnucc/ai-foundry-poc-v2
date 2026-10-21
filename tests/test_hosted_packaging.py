import importlib.util
import io
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import zipfile

spec = importlib.util.spec_from_file_location("hosted_packaging", Path(__file__).resolve().parents[1] / "hosted-agent.py")
hosted = importlib.util.module_from_spec(spec)
spec.loader.exec_module(hosted)


class PackagingTests(unittest.TestCase):
    def test_excluded_paths_are_not_statted_or_uploaded(self):
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory)
            (source / "main.py").write_text("print('demo')")
            (source / ".venv").mkdir()
            (source / ".venv" / "unreadable").write_text("not source")
            original = Path.is_file

            def is_file(path):
                if ".venv" in path.parts:
                    raise OSError("Windows cannot stat a WSL symlink")
                return original(path)

            with patch.object(Path, "is_file", is_file):
                code = hosted.build_zip(source)
            with zipfile.ZipFile(io.BytesIO(code)) as archive:
                self.assertEqual(archive.namelist(), ["main.py"])
