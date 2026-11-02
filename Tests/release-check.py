import importlib.util
from pathlib import Path
import tempfile
import struct
import zipfile

spec = importlib.util.spec_from_file_location('release', Path(__file__).parents[1] / 'scripts/release.py')
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)
with tempfile.TemporaryDirectory() as temp:
    output = Path(temp)
    prefix = '显示器切换-macOS-AppleSilicon'
    old = output / f'{prefix}-v2.9.zip'
    unrelated = output / 'other-app-v1.0.zip'
    windows = output / '显示器切换-Windows-x64-v2.13.zip'
    future = output / f'{prefix}-v3.0.zip'
    for file in [old, unrelated, windows, future]:
        file.write_bytes(b'keep')
    staged = output / 'staged.zip'
    required = '显示器切换.app/Contents/MacOS/app'
    with zipfile.ZipFile(staged, 'w') as archive:
        archive.writestr('wrong-entry', 'data')
    try:
        release.publish(staged, output, prefix, '2.15', required)
        raise AssertionError('Incomplete archive accepted')
    except ValueError:
        assert old.read_bytes() == b'keep'
        assert not (output / f'{prefix}-v2.15.zip').exists()
    with zipfile.ZipFile(staged, 'w') as archive:
        archive.writestr(required, 'data')
    # Exercise ditto's unflagged UTF-8 filenames as well as standard ZIPs.
    raw = bytearray(staged.read_bytes())
    for signature, offset in [(b'PK\x03\x04', 6), (b'PK\x01\x02', 8)]:
        struct.pack_into('<H', raw, raw.index(signature) + offset, 0)
    staged.write_bytes(raw)
    result = release.publish(staged, output, prefix, '2.15', required)
    assert result.is_file() and not old.exists()
    assert all(file.read_bytes() == b'keep' for file in [unrelated, windows, future])
print('Release validation and per-platform old-version cleanup passed')
