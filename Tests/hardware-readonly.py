"""Optional local smoke check: queries only; missing target prevents every write."""
import json
import subprocess

helper = 'build/显示器切换.app/Contents/Resources/input-ddc'
def run(*args):
    return json.loads(subprocess.check_output([helper, *args]))
displays = run('list')['displays']
serials = [d['serial'] for d in displays if d['serial']]
for serial in serials:
    value = run('get', serial)
    assert value['ok'] and value['input'] in (15, 17, 27)
    level = run('brightness-get', serial)
    assert level['ok'] and 0 <= level['brightness'] <= level['maxBrightness'] <= 65535
    assert level['maxBrightness'] > 0
if serials:
    # The valid display is opened but receives no write, because another target is missing.
    for field, target in [('input', 27), ('brightness', 20)]:
        result = run('batch', json.dumps([{'serial': serials[0], field: target}, {'serial': '__missing_readonly_check__', field: target}]))
        assert len(result['results']) == 2
        assert all(not r['ok'] and r.get('error') and 'videoSent' not in r and 'brightnessSent' not in r for r in result['results'])
for op in [{'brightness': -1}, {'brightness': 101}, {'brightness': True}, {'brightness': 1.5}, {'input': 15, 'usbMask': 1}]:
    result = subprocess.run([helper, 'batch', json.dumps([dict(serial='__validation_only__', **op)])], capture_output=True, text=True)
    assert result.returncode != 0 and not json.loads(result.stdout)['ok']
print(f'Read-only hardware smoke passed: {len(serials)} displays; batch preflight refused incomplete group')
