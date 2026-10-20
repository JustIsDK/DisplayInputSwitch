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
if serials:
    # The valid display is opened but receives no write, because another target is missing.
    result = run('batch', json.dumps([{'serial': serials[0], 'input': 27}, {'serial': '__missing_readonly_check__', 'input': 15}]))
    assert len(result['results']) == 2
    assert all(not r['ok'] and r.get('error') and 'videoSent' not in r and 'usbSent' not in r for r in result['results'])
print(f'Read-only hardware smoke passed: {len(serials)} displays; batch preflight refused incomplete group')
