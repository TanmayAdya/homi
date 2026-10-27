#!/usr/bin/env python3
"""Prepare pinned trial artifacts in ignored local folders."""
import argparse
import hashlib
import json
import plistlib
import shutil
import struct
import tarfile
import urllib.request
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CACHE = ROOT / 'build/homi-local-llm'
COMMIT = 'd854d98bae598388ecea1ed84396587e5edc326d'
SOURCE_SHA = '7d1fc4a3e5b202fc5136bd52948c73e5e2a112cbbc6fdf9156ffc7f05d4fd918'
FRAMEWORK_SHA = 'c7e98ed7e75f29ca90c311dd00c303efa982c54f523e81312db27f9b066c828f'
MODEL_SHA = '9465e63a22add5354d9bb4b99e90117043c7124007664907259bd16d043bb031'
MODEL_REVISION = '23749fefcc72300e3a2ad315e1317431b06b590a'
MODEL_FILE = 'Qwen3-0.6B-Q8_0.gguf'
LICENSES = {
    'llama-MIT.txt': ('https://raw.githubusercontent.com/ggml-org/llama.cpp/' + COMMIT + '/LICENSE',
                      '94f29bbed6a22c35b992c5c6ebf0e7c92f13b836b90f36f461c9cf2f0f1d010d'),
    'Qwen-Apache-2.0.txt': ('https://huggingface.co/Qwen/Qwen3-0.6B-GGUF/raw/' + MODEL_REVISION + '/LICENSE',
                            '5de36594c10839788a8c589443a8ef9d8b8d17c65a1b5807206ae037fc36c6bd'),
}


def digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def download(url, target, expected=None, expected_size=None):
    if target.is_file() and (expected is None or digest(target) == expected):
        if expected_size is None or target.stat().st_size == expected_size:
            return
    target.parent.mkdir(parents=True, exist_ok=True)
    temporary = target.with_suffix(target.suffix + '.part')
    try:
        with urllib.request.urlopen(url, timeout=45) as response, temporary.open('wb') as output:
            shutil.copyfileobj(response, output, length=1024 * 1024)
        if expected is not None and digest(temporary) != expected:
            raise ValueError('Artifact checksum differs from the pinned publisher metadata.')
        if expected_size is not None and temporary.stat().st_size != expected_size:
            raise ValueError('Artifact size differs from the pinned publisher metadata.')
        temporary.replace(target)
    finally:
        temporary.unlink(missing_ok=True)


def prepare_runtime():
    archive = CACHE / 'llama-source.tar.gz'
    download('https://codeload.github.com/ggml-org/llama.cpp/tar.gz/' + COMMIT, archive, SOURCE_SHA)
    source = CACHE / 'source'
    if not source.is_dir():
        staging = CACHE / 'source-unpack'
        staging.mkdir(exist_ok=True)
        with tarfile.open(archive) as bundle:
            bundle.extractall(staging, filter='data')
        extracted = staging / ('llama.cpp-' + COMMIT)
        if digest(extracted / 'LICENSE') != LICENSES['llama-MIT.txt'][1]:
            raise ValueError('Runtime license does not match the pinned source.')
        extracted.replace(source)
        staging.rmdir()

    with tarfile.open(archive) as bundle:
        for member in bundle.getmembers():
            if member.isfile():
                relative = Path(member.name).relative_to('llama.cpp-' + COMMIT)
                cached = source / relative
                expected = hashlib.file_digest(bundle.extractfile(member), 'sha256').hexdigest()
                if not cached.is_file() or digest(cached) != expected:
                    raise ValueError('Extracted runtime source differs from the pinned archive: ' + str(relative))
    apple = CACHE / 'llama-b11889-xcframework.zip'
    download('https://github.com/ggml-org/llama.cpp/releases/download/b11889/llama-b11889-xcframework.zip',
             apple, FRAMEWORK_SHA, 68200998)
    generated = ROOT / 'packages/homi_local_llm/ios/.generated'
    generated.mkdir(parents=True, exist_ok=True)
    if not (generated / 'llama.xcframework').is_dir():
        unpack = CACHE / 'apple-unpack'
        unpack.mkdir(exist_ok=True)
        with zipfile.ZipFile(apple) as bundle:
            for item in bundle.infolist():
                if not (unpack / item.filename).resolve().is_relative_to(unpack.resolve()):
                    raise ValueError('Invalid archive path.')
            bundle.extractall(unpack)
        frameworks = list(unpack.rglob('llama.xcframework'))
        if len(frameworks) != 1:
            raise ValueError('Expected exactly one runtime XCFramework.')
        shutil.copytree(frameworks[0], generated / 'llama.xcframework')
    with zipfile.ZipFile(apple) as bundle:
        for item in bundle.infolist():
            parts = Path(item.filename).parts
            if item.is_dir() or 'llama.xcframework' not in parts:
                continue
            relative = Path(*parts[parts.index('llama.xcframework'):])
            cached = generated / relative
            with bundle.open(item) as stream:
                expected = hashlib.file_digest(stream, 'sha256').hexdigest()
            if not cached.is_file() or digest(cached) != expected:
                raise ValueError('Extracted Apple runtime differs from the pinned archive: ' + str(relative))


    upstream = generated / 'llama.xcframework'
    info = plistlib.loads((upstream / 'Info.plist').read_bytes())
    libraries = [entry for entry in info['AvailableLibraries'] if entry['SupportedPlatform'] == 'ios']
    if len(libraries) != 1 or libraries[0]['LibraryIdentifier'] != 'ios-arm64':
        raise ValueError('Unexpected iOS slices in the pinned runtime archive.')
    binary = upstream / 'ios-arm64' / libraries[0]['BinaryPath']
    magic, cpu, _, kind = struct.unpack('<IIII', binary.read_bytes()[:16])
    if magic != 0xFEEDFACF or cpu != 0x0100000C or kind != 6:
        raise ValueError('Expected the publisher iOS arm64 dynamic framework.')

    derived = generated / 'ios' / 'llama.xcframework'
    derived.parent.mkdir(exist_ok=True)
    expected_info = {**info, 'AvailableLibraries': libraries}
    if not derived.exists():
        temporary = derived.with_suffix('.xcframework.part')
        if temporary.exists():
            shutil.rmtree(temporary)
        temporary.mkdir()
        shutil.copytree(upstream / 'ios-arm64', temporary / 'ios-arm64')
        (temporary / 'Info.plist').write_bytes(plistlib.dumps(expected_info))
        temporary.replace(derived)
    if plistlib.loads((derived / 'Info.plist').read_bytes()) != expected_info:
        raise ValueError('Derived iOS runtime manifest differs from the pinned selection.')
    expected_files = {p.relative_to(upstream / 'ios-arm64') for p in (upstream / 'ios-arm64').rglob('*') if p.is_file()}
    actual_files = {p.relative_to(derived / 'ios-arm64') for p in (derived / 'ios-arm64').rglob('*') if p.is_file()}
    if actual_files != expected_files or {p.name for p in derived.iterdir()} != {'Info.plist', 'ios-arm64'}:
        raise ValueError('Derived iOS runtime contains unexpected files or slices.')
    for relative in expected_files:
        if digest(derived / 'ios-arm64' / relative) != digest(upstream / 'ios-arm64' / relative):
            raise ValueError('Derived iOS runtime slice is not byte-identical to the verified upstream slice.')
    return {'commit': COMMIT, 'sourceArchiveSha256': digest(archive), 'appleArchiveSha256': FRAMEWORK_SHA}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--runtime', action='store_true')
    parser.add_argument('--model', action='store_true')
    args = parser.parse_args()
    if not args.runtime and not args.model:
        parser.error('Choose --runtime and/or --model explicitly.')
    CACHE.mkdir(parents=True, exist_ok=True)
    for name, (url, expected) in LICENSES.items():
        download(url, CACHE / 'licenses' / name, expected)
    manifest = {'runtimeCommit': COMMIT, 'modelRevision': MODEL_REVISION,
                'modelSha256': MODEL_SHA, 'modelBytes': 639446688}
    if args.runtime:
        manifest.update(prepare_runtime())
    if args.model:
        download('https://huggingface.co/Qwen/Qwen3-0.6B-GGUF/resolve/' + MODEL_REVISION + '/' + MODEL_FILE,
                 CACHE / MODEL_FILE, MODEL_SHA, 639446688)
    (CACHE / 'verified-artifacts.json').write_text(json.dumps(manifest, indent=2) + '\n')
    print('Pinned trial artifacts and licenses verified in ignored build/homi-local-llm.')


if __name__ == '__main__':
    main()
