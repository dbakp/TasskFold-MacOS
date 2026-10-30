#!/usr/bin/env python3
"""Render the reviewed Px snapshot. No network, app data, or sibling-repo dependency."""
import argparse
from collections import Counter
from datetime import date
from html import escape
import hashlib
import json
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]
DOCS = ROOT / 'docs'
DATA = DOCS / 'px-progress.json'
TEMPLATE = Path(__file__).with_name('px-progress-template.html')
STATES = {
    'done': ('Verified', 'var(--viz-series-1)', '✓'),
    'verify': ('Built · checks left', 'var(--viz-series-2)', '◐'),
    'build': ('To build', 'var(--muted)', '○'),
    'deferred': ('Deferred', 'var(--viz-series-3)', 'Ⅱ'),
}


def validate(data):
    assert data['schema'] == 1
    date.fromisoformat(data['updated'])
    assert [s['id'] for s in data['stages']] == ['p0', 'p1', 'p2']
    seen = set()
    sources = set(data['sources'])
    for stage in data['stages']:
        for group in stage['groups']:
            key = group['id']
            assert re.fullmatch(r'p[012]-[a-z0-9-]+', key) and key not in seen, key
            seen.add(key)
            assert group['items'] and group['sources']
            sources.update(group['sources'])
            for item in group['items']:
                assert item['state'] in STATES and item['title'].strip()
    hashes = {}
    for ref in sorted(sources):
        assert re.fullmatch(r'[A-Za-z0-9_./-]+', ref), ref
        path = (DOCS / ref).resolve()
        assert path.is_relative_to(DOCS.resolve()) and path.suffix in ('.md', '.json') and path.is_file(), ref
        hashes[ref] = hashlib.sha256(path.read_bytes()).hexdigest()
    return hashes


def counts(items):
    return Counter(item['state'] for item in items)


def count_text(items):
    c = counts(items)
    labels = {'done': 'verified', 'verify': 'built / checks left', 'build': 'to build', 'deferred': 'deferred'}
    return ' · '.join(f'{c[state]} {labels[state]}' for state in STATES if c[state])


def meter(items):
    c = counts(items)
    total = len(items)
    x = 0
    parts = []
    for state, (_, color, _) in STATES.items():
        if c[state]:
            fill = 'var(--muted)' if state == 'build' else color
            parts.append(f'<rect x="{x}" y="0" width="{c[state]}" height="1" fill="{fill}"/>')
            x += c[state]
    return f'<svg class="px-meter" viewBox="0 0 {total} 1" preserveAspectRatio="none" role="img" aria-label="{escape(count_text(items), quote=True)}">' + ''.join(parts) + '</svg>'


def summary(title, items, focus=False):
    badge = '<span class="viz-badge">Working here</span>' if focus else ''
    return '<span class="px-summary"><span class="px-heading"><span class="px-title">' + escape(title) + '</span>' + badge + '</span><span class="text-small text-muted" aria-hidden="true">' + escape(count_text(items)) + '</span>' + meter(items) + '</span>'


def render(data, links=False):
    out = [f'<header class="px-head"><h1>{escape(data["title"])}</h1><span class="text-small text-muted">Reviewed <time datetime="{data["updated"]}">{date.fromisoformat(data["updated"]).strftime("%d %b %Y")}</time></span></header>']
    out.append(f'<div class="px-intro">{escape(data["headline"])}</div>')
    out.append('<div class="px-legend" aria-label="Milestone states">')
    for label, color, _ in STATES.values():
        out.append(f'<span class="px-key text-small"><span class="px-swatch" style="background:{color}" aria-hidden="true"></span>{escape(label)}</span>')
    out.append('</div><div class="text-small text-muted">Bars count tracked checkpoints, not effort or release readiness. “Verified” means the recorded scope.</div>')
    out.append(f'<details id="px-latest" data-remember><summary class="cursor-interaction">Latest · {escape(data["focus"])}</summary><div>{escape(data["latest"])}</div></details>')
    for stage in data['stages']:
        all_items = [item for group in stage['groups'] for item in group['items']]
        opened = ' open' if stage['id'] == 'p2' else ''
        out.append(f'<details class="px-stage" id="px-{stage["id"]}" data-remember{opened}><summary class="cursor-interaction">{summary(stage["title"], all_items)}</summary><div class="text-small text-muted px-intro">{escape(stage["summary"])}</div>')
        for group in stage['groups']:
            out.append(f'<details class="px-group" id="{group["id"]}" data-remember><summary class="cursor-interaction">{summary(group["title"], group["items"], group.get("focus", False))}</summary><ul class="px-items">')
            for index, item in enumerate(group['items']):
                label, color, glyph = STATES[item['state']]
                glyph_color = 'var(--muted-foreground)' if item['state'] == 'build' else color
                out.append(f'<li class="px-item" data-state="{item["state"]}" id="{group["id"]}-item-{index}"><span style="color:{glyph_color}" aria-hidden="true">{glyph}</span><div><div class="px-item-head"><span class="px-item-title">{escape(item["title"])}</span><span class="text-small text-muted">{escape(label)}</span></div>')
                if item.get('detail'):
                    out.append(f'<div class="px-item-detail text-small text-muted">{escape(item["detail"])}</div>')
                out.append('</div></li>')
            out.append(f'</ul><details class="px-sources" id="{group["id"]}-evidence" data-remember><summary class="cursor-interaction text-small">Evidence for this section</summary><ul class="px-source-list text-small">')
            for ref in group['sources']:
                label = escape(ref)
                out.append(f'<li><a href="{escape(ref, quote=True)}" target="_blank" rel="noopener">{label}</a></li>' if links else f'<li>{label}</li>')
            out.append('</ul></details></details>')
        out.append('</details>')
    out.append('<footer class="px-footer"><details id="px-next" data-remember><summary class="cursor-interaction">Next in the active work</summary><ol>')
    out.extend(f'<li>{escape(step)}</li>' for step in data['next'])
    out.append('</ol></details><div class="text-small text-muted">Both apps own their dashboard and sources. Reviewed snapshot; no live telemetry or completion-date estimate.</div></footer>')
    fragment = TEMPLATE.read_text().replace('<!--PX_CONTENT-->', '\n'.join(out))
    assert '<!--PX_CONTENT-->' not in fragment and len(fragment.encode()) < 1_000_000
    return fragment


STANDALONE_CSS = '''
:root { color-scheme: light dark; --background: Canvas; --foreground: CanvasText; --muted: color-mix(in srgb, CanvasText 10%, Canvas); --muted-foreground: color-mix(in srgb, CanvasText 72%, Canvas); --border: color-mix(in srgb, CanvasText 18%, Canvas); --viz-series-1: Highlight; --viz-series-2: color-mix(in srgb, Mark 55%, CanvasText); --viz-series-3: GrayText; }
* { box-sizing: border-box; }
body { margin: 0 auto; padding: 24px; max-width: 880px; background: var(--background); color: var(--foreground); font: 14px/1.5 system-ui, sans-serif; }
h1 { font-size: 1.4em; font-weight: 500; }
.text-small { font-size: 12px; }
.text-muted { color: var(--muted-foreground); }
.viz-badge { background: var(--muted); border-radius: 6px; padding: 2px 7px; font-size: 12px; }
a { color: LinkText; }
@media (max-width: 480px) { body { padding: 16px; } }
'''
FALLBACK_STATE = '''
if (!window.openai) {
  let saved;
  try { saved = JSON.parse(localStorage.getItem('taskfold-px-ui') || 'null'); } catch (_) {}
  window.openai = { widgetState: saved, setWidgetState(state) {
    this.widgetState = state;
    try { localStorage.setItem('taskfold-px-ui', JSON.stringify(state)); } catch (_) {}
    return Promise.resolve();
  }};
}
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--refresh-sources', action='store_true', help='After reviewing the snapshot, record current evidence-source hashes and render')
    parser.add_argument('--check', action='store_true', help='Refuse stale evidence or generated output without writing')
    parser.add_argument('--preview-output', type=Path, help='Also copy the inline fragment to an explicitly chosen conversation preview path')
    args = parser.parse_args()
    if args.check and (args.refresh_sources or args.preview_output):
        parser.error('--check is read-only')
    data = json.loads(DATA.read_text())
    hashes = validate(data)
    if args.refresh_sources:
        data['source_hashes'] = hashes
        DATA.write_text(json.dumps(data, ensure_ascii=False, indent=2) + '\n')
    if data.get('source_hashes') != hashes:
        parser.error('Evidence sources changed. Review px-progress.json, then use --refresh-sources.')
    fragment = render(data)
    standalone = '<!doctype html>\n<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Taskfold progress</title><style>' + STANDALONE_CSS + '</style><script>' + FALLBACK_STATE + '</script></head><body>\n' + render(data, links=True) + '\n</body></html>\n'
    outputs = {DOCS / 'px-progress.fragment.html': fragment, DOCS / 'PX_PROGRESS.html': standalone}
    for path, content in outputs.items():
        if args.check:
            assert path.read_text() == content, f'Stale generated output: {path}'
        else:
            path.write_text(content)
    if args.preview_output:
        args.preview_output.parent.mkdir(parents=True, exist_ok=True)
        args.preview_output.write_text(fragment)
    total = sum(len(g['items']) for s in data['stages'] for g in s['groups'])
    print(f'{"Checked" if args.check else "Rendered"} {total} checkpoints; reviewed {data["updated"]}; evidence hashes match.')


if __name__ == '__main__':
    main()
