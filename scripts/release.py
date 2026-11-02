#!/usr/bin/env python3
"""Package built apps; replace older releases only after the new archive passes validation."""
import argparse
import os
from pathlib import Path
import plistlib
import re
import subprocess
import tempfile
import xml.etree.ElementTree as ET
import zipfile

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_OUTPUT = Path('/Volumes/sata11-185XXXX1365/工具')


def version_tuple(value):
    if not re.fullmatch(r'\d+(?:\.\d+){1,3}', value):
        raise ValueError(f'Invalid release version: {value}')
    return tuple(int(part) for part in value.split('.')) + (0,) * (4 - len(value.split('.')))


def publish(staged, output, prefix, version, required):
    current = version_tuple(version)
    # ditto stores UTF-8 names without setting the ZIP UTF-8 flag.
    with zipfile.ZipFile(staged, metadata_encoding='utf-8') as archive:
        if required not in archive.namelist() or archive.testzip() is not None:
            raise ValueError('新包内容不完整或校验失败，保留所有旧包。')
    destination = output / f'{prefix}-v{version}.zip'
    os.replace(staged, destination)
    pattern = re.compile(re.escape(prefix) + r'-v(\d+(?:\.\d+){1,3})\.zip')
    for old in output.iterdir():
        match = pattern.fullmatch(old.name)
        if match and old.is_file() and version_tuple(match[1]) < current:
            old.unlink()
            print(f'已删除旧包：{old.name}')
    print(f'已输出并校验：{destination}')
    return destination


def package(platform, output):
    if platform == 'macos':
        source = ROOT / 'build/显示器切换.app'
        with (source / 'Contents/Info.plist').open('rb') as file:
            version = plistlib.load(file)['CFBundleShortVersionString']
        with (ROOT / 'Info.plist').open('rb') as file:
            if version != plistlib.load(file)['CFBundleShortVersionString']:
                raise ValueError('Mac 构建版本过旧，请先运行 zsh build.sh。')
        subprocess.run(['codesign', '--verify', '--deep', '--strict', str(source)], check=True)
        prefix = '显示器切换-macOS-AppleSilicon'
        required = '显示器切换.app/Contents/MacOS/DisplayInputSwitch'
    else:
        source = ROOT / 'build/windows-x64'
        version = ET.parse(ROOT / 'Windows/DisplayInputSwitch.csproj').findtext('./PropertyGroup/Version')
        version = version.removesuffix('.0')
        prefix, required = '显示器切换-Windows-x64', 'DisplayInputSwitch.exe'
        if not (source / required).is_file():
            raise ValueError('请先运行 zsh build-windows.sh。')
    # Stage on the destination volume so final replacement is a single rename.
    with tempfile.TemporaryDirectory(prefix='.DisplayInputSwitch-', dir=output) as temp:
        staged = Path(temp) / 'release.zip'
        if platform == 'macos':
            subprocess.run(['ditto', '-c', '-k', '--sequesterRsrc', '--keepParent', str(source), str(staged)], check=True)
        else:
            with zipfile.ZipFile(staged, 'w', zipfile.ZIP_DEFLATED) as archive:
                for file in sorted(source.rglob('*')):
                    if file.is_file() and file.suffix != '.pdb':
                        archive.write(file, file.relative_to(source))
        publish(staged, output, prefix, version, required)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('platform', choices=['macos', 'windows', 'all'])
    parser.add_argument('--output', type=Path, default=Path(os.environ.get('DISPLAYINPUTSWITCH_RELEASE_DIR', DEFAULT_OUTPUT)))
    args = parser.parse_args()
    if not args.output.is_dir():
        parser.error(f'输出目录不存在（请确认磁盘已挂载）：{args.output}')
    for platform in (['macos', 'windows'] if args.platform == 'all' else [args.platform]):
        package(platform, args.output)


if __name__ == '__main__':
    main()
