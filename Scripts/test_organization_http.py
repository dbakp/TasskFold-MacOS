#!/usr/bin/env python3
"""Two-device PostgREST checks using disposable fixture accounts provisioned by the operator.
Input JSON has users [uuid, uuid] and password; emails are taskfold-views-<uuid>@example.invalid.
Never uses real task data or service-role credentials. Delete both accounts after the run.
"""
import argparse, json, plistlib, uuid
from pathlib import Path
from urllib.request import Request, urlopen
from urllib.error import HTTPError

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('fixture', type=Path)
parser.add_argument('--configuration', type=Path, default=Path(__file__).resolve().parents[1] / 'Taskfold/Backend.plist')
args = parser.parse_args()
fixture = json.loads(args.fixture.read_text())
config = plistlib.loads(args.configuration.read_bytes())
base, key = config['URL'], config['Key']

def request(path, method='GET', body=None, token=None, expected=200):
    headers = {'apikey': key, 'Content-Type': 'application/json', 'Prefer': 'resolution=merge-duplicates,return=representation'}
    if token: headers['Authorization'] = 'Bearer ' + token
    data = None if body is None else json.dumps(body).encode()
    try:
        with urlopen(Request(base + path, data=data, headers=headers, method=method), timeout=20) as response:
            status, raw = response.status, response.read()
    except HTTPError as error:
        status, raw = error.code, error.read()
    assert status == expected, f'{method} {path.split("?")[0]}: HTTP {status}, expected {expected}; code=' + str(json.loads(raw).get('code')) + '; message=' + str(json.loads(raw).get('message'))
    return json.loads(raw) if raw else None

def login(user):
    return request('/auth/v1/token?grant_type=password', 'POST', {'email': f'taskfold-views-{user}@example.invalid', 'password': fixture['password']})['access_token']

def rows(table, token, record=None):
    return request('/rest/v1/' + table + ('?id=eq.' + record if record else '?select=*'), token=token)

def post(table, row, token, expected=201):
    composite = 'user_id,id' if table in ['favorites', 'view_preferences', 'view_orders'] else 'id'
    return request('/rest/v1/' + table + '?on_conflict=' + composite, 'POST', row, token, expected)

def patch(table, record, changes, token):
    return request('/rest/v1/' + table + '?id=eq.' + record, 'PATCH', changes, token)

owner, outsider = fixture['users']
a, b, foreign = login(owner), login(owner), login(outsider)
project, task, view = [str(uuid.uuid4()) for _ in range(3)]
post('projects', {'id': project, 'user_id': owner, 'name': 'Fixture studio'}, a)
post('tasks', {'id': task, 'user_id': owner, 'project_id': project, 'title': 'Fixture handoff', 'due_date': '2026-10-06', 'deadline_date': '2026-10-09', 'duration_minutes': 25}, a)
query = {'version': 1, 'root': {'op': 'predicate', 'field': 'project', 'value': project}}
post('saved_views', {'id': view, 'user_id': owner, 'name': 'Fixture focus', 'query_ast': query, 'layout': 'board', 'grouping': 'priority'}, a)
post('favorites', {'id': 'view:' + view, 'user_id': owner, 'order_index': 1}, a)
post('view_preferences', {'id': 'today', 'user_id': owner, 'sort_by': 'duration', 'priority_filter': 1}, a)
order_key = 'scope:view:' + view + ':group:all'
post('view_orders', {'id': order_key, 'user_id': owner, 'ids': [task]}, a)
assert rows('saved_views', b, view)[0]['query_ast'] == query
assert rows('tasks', b, task)[0]['duration_minutes'] == 25
assert rows('favorites', b)[0]['id'] == 'view:' + view
patch('saved_views', view, {'name': 'Renamed on second device', 'sort_by': 'deadline'}, b)
patch('view_preferences', 'today', {'include_completed': True}, b)
post('view_preferences', {'id': 'today', 'user_id': owner, 'overdue_collapsed': True}, b, 200)
prefs = rows('view_preferences', a)[0]
assert prefs['sort_by'] == 'duration' and prefs['priority_filter'] == 1 and prefs['include_completed'] and prefs['overdue_collapsed'], 'Partial upsert erased another preference'
assert rows('saved_views', a, view)[0]['name'] == 'Renamed on second device'
patch('tasks', task, {'deadline_date': '2026-10-10', 'duration_minutes': 45}, b)
assert rows('tasks', a, task)[0]['deadline_date'] == '2026-10-10'
for table in ['saved_views', 'favorites', 'view_preferences', 'view_orders', 'tasks', 'projects']:
    assert rows(table, foreign) == [], 'Foreign data visible in ' + table
post('favorites', {'id': 'today', 'user_id': owner}, foreign, 403)
post('view_preferences', {'id': 'today', 'user_id': outsider, 'sort_by': 'title'}, foreign)
assert rows('view_preferences', a)[0]['sort_by'] == 'duration'
post('view_orders', {'id': order_key, 'user_id': owner, 'ids': [task, 'new-offline-task']}, b, 200)
assert rows('view_orders', a)[0]['ids'] == [task, 'new-offline-task']
request('/rest/v1/saved_views?id=eq.' + view, 'DELETE', token=b)
assert rows('saved_views', a) == [] and rows('tasks', a, task)[0]['id'] == task
print('PASS: two sessions read/write tasks, planning fields, saved views, favorites, partial preferences and stable list order; foreign account isolated.')
