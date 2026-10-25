import ast
import hashlib
import json
import os
from pathlib import Path
import tempfile
import time
import types
import unittest


class OCRSetupTests(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.TemporaryDirectory(prefix='shiori-setup-test-')
        self.addCleanup(self.folder.cleanup)
        self.root = Path(self.folder.name)
        self.payload = b'verified model payload'
        self.calls = 0
        owner = self
        class Response:
            headers = {'content-length': str(len(owner.payload))}
            def __enter__(self): return self
            def __exit__(self, *args): pass
            def raise_for_status(self): pass
            def iter_content(self, _): yield owner.payload
        def get(*args, **kwargs):
            self.calls += 1
            return Response()
        tree = ast.parse((Path(__file__).parents[1] / 'Scripts/setup_ocr.py').read_text())
        function = next(node for node in tree.body if isinstance(node, ast.FunctionDef) and node.name == 'weights')
        self.context = dict(models=self.root, hashlib=hashlib, os=os, verify_only=False,
                            requests=types.SimpleNamespace(get=get), json=json, time=time)
        exec(compile(ast.Module(body=[function], type_ignores=[]), 'setup_ocr.py', 'exec'), self.context)
        self.weights = self.context['weights']
        self.expected = hashlib.sha256(self.payload).hexdigest()
        self.model = self.root / 'model.bin'

    def test_existing_valid_model_stays_offline(self):
        self.model.write_bytes(self.payload)
        self.weights('model.bin', 'https://example.invalid/model', self.expected)
        self.assertEqual(self.calls, 0)

    def test_repair_replaces_corrupt_model_after_verification(self):
        self.model.write_bytes(b'corrupt')
        self.weights('model.bin', 'https://example.invalid/model', self.expected)
        self.assertEqual(self.model.read_bytes(), self.payload)
        self.assertEqual(self.calls, 1)

    def test_bad_download_preserves_existing_file(self):
        self.model.write_bytes(b'previous file')
        with self.assertRaises(RuntimeError):
            self.weights('model.bin', 'https://example.invalid/model', '0' * 64)
        self.assertEqual(self.model.read_bytes(), b'previous file')
        self.assertFalse(self.model.with_suffix('.download').exists())

    def test_verify_only_never_downloads(self):
        self.context['verify_only'] = True
        with self.assertRaises(RuntimeError):
            self.weights('model.bin', 'https://example.invalid/model', self.expected)
        self.assertEqual(self.calls, 0)


if __name__ == '__main__':
    unittest.main()
