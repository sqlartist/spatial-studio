import base64, pathlib, json, sys
h = pathlib.Path(__file__).parent
t = (h/'template.html').read_text()
t = t.replace('__DATA__', (h/'data.json').read_text()).replace('__LAND__', (h/'land.json').read_text())
t = t.replace('__PORTRAIT__', 'data:image/jpeg;base64,' + base64.b64encode((h/'portrait.jpg').read_bytes()).decode())
(h/'ai-man-tracker.html').write_text(t)
# local test copy: d3 from disk, full html skeleton
local = '<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">' + \
        t.replace('https://cdnjs.cloudflare.com/ajax/libs/d3/7.9.0/d3.min.js', 'package/dist/d3.min.js') + '</html>'
(h/'local.html').write_text(local)
print(len(t)//1024, 'KB')
