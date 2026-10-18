"""Install model weights into the app's isolated OCR directory."""
from pathlib import Path
from concurrent.futures import ThreadPoolExecutor
import hashlib
import os
import requests
os.environ['HF_HUB_DISABLE_XET'] = '1'
from huggingface_hub import snapshot_download

root = Path.home() / 'Library/Application Support/Shiori/OCR'
models = root / 'models'
models.mkdir(parents=True, exist_ok=True)

def weights(name, url, expected):
    path = models / name
    if not path.exists():
        temporary = path.with_suffix('.download')
        with requests.get(url, stream=True, timeout=(30, 120)) as response:
            response.raise_for_status()
            with temporary.open('wb') as output:
                for chunk in response.iter_content(1024 * 1024):
                    output.write(chunk)
        if hashlib.sha256(temporary.read_bytes()).hexdigest() != expected:
            temporary.unlink()
            raise RuntimeError(name + ' failed checksum verification')
        os.replace(temporary, path)
    digest = hashlib.sha256(path.read_bytes()).hexdigest()
    if digest != expected:
        raise RuntimeError(name + ' failed checksum verification')
    print(name + ' ready', digest, flush=True)


def detector():
    weights('comictextdetector.pt',
            'https://github.com/zyddnys/manga-image-translator/releases/download/beta-0.2.1/comictextdetector.pt',
            '1f90fa60aeeb1eb82e2ac1167a66bf139a8a61b8780acd351ead55268540cccb')


def inpainting():
    weights('big-lama.pt',
            'https://github.com/enesmsahin/simple-lama-inpainting/releases/download/v0.1.0/big-lama.pt',
            '7ba7aa7ac37a4d41fdbbeba3a2af7ead18058552997e3a3cd1a3b2210c9e6b4c')

def recognition():
    snapshot_download('kha-white/manga-ocr-base', revision='aa6573bd10b0d446cbf622e29c3e084914df9741',
                      local_dir=models / 'manga', allow_patterns=['*.json', '*.bin', 'vocab.txt'])
    digest = hashlib.sha256((models / 'manga/pytorch_model.bin').read_bytes()).hexdigest()
    if digest != 'c63e0bb5b3ff798c5991de18a8e0956c7ee6d1563aca6729029815eda6f5c2eb':
        raise RuntimeError('OCR weights failed checksum verification')
    print('recognizer ready', digest, flush=True)

with ThreadPoolExecutor(max_workers=3) as pool:
    futures = [pool.submit(detector), pool.submit(recognition), pool.submit(inpainting)]
    for future in futures:
        future.result()
