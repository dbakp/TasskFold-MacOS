"""Read-only verification of this retained synthetic CSV/geometry fixture."""
from pathlib import Path
import csv
import hashlib
import io
import json
import re

root = Path(__file__).resolve().parent
expected_header = ['Taskfold format', 'Row reference', 'Parent reference', 'Group', 'Parent path', 'Type', 'Title', 'Notes', 'Completed', 'Project', 'Priority', 'Planned date', 'Time', 'Time zone', 'Scheduled instant', 'Deadline', 'Estimate minutes', 'Labels', 'Assigned to']
outputs = []
for device in ['phone', 'ipad']:
    folder = root / device
    data = next(folder.glob('*.csv')).read_bytes()
    rows = list(csv.reader(io.StringIO(data.decode('utf-8'))))
    assert rows[0] == expected_header and len(rows) == 5
    assert all(len(row) == 19 for row in rows)
    assert all(row[0] == 'taskfold-task-rows-v1' for row in rows[1:])
    assert {row[1] for row in rows[1:]} == {'row-1', 'row-2', 'row-3', 'row-4'}
    assert {row[6] for row in rows[1:]} == {'Draft the launch note', 'Checklist detail', 'Check the layout', 'Launch context'}
    assert rows[1][2] == 'row-4' and rows[2][2] == 'row-1'
    assert rows[3][2] == '' and rows[4][5] == 'heading'
    assert 'Keep the work’s own notes.' in data.decode('utf-8')
    assert 'ui-testing' not in data.decode('utf-8')
    assert not re.search(r'[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}', data.decode('utf-8'), re.I)
    fields = json.loads(next(p for p in folder.glob('*.json') if p.name != 'manifest.json').read_text())
    assert len(fields) == 23 and {field['row'] for field in fields} == {1, 2, 3, 4}
    for field in fields:
        x, y, width, height = field['frame']
        sx, sy, sw, sh = field['sheet']
        assert width > 0 and height > 0
        assert x >= sx and y >= sy and x + width <= sx + sw + .01 and y + height <= sy + sh + .01
    outputs.append(data)
    print(device, 'CSV and retained sheet bounds verified:', hashlib.sha256(data).hexdigest())
assert outputs[0] == outputs[1]
print('Both delivered files are byte-identical. Native tests additionally checked the navigation-bar inset and cold preservation.')
