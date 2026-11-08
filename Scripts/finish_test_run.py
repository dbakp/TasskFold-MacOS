#!/usr/bin/env python3
"""Bound completed Taskfold compiler caches and retired Simulator wallpaper scratch.

Only explicitly named Taskfold caches/devices are eligible. Never erases a device,
app container, result bundle, app product, source checkout, or device-support cache.
"""
import argparse
import json
from pathlib import Path
import shutil
import subprocess


def allocated(path):
    return sum(p.lstat().st_blocks * 512 for p in path.rglob('*') if p.is_file() and not p.is_symlink()) if path.exists() else 0


def finish(simulators=(), build_caches=(), apply=False):
    report = {'apply': apply, 'freeBeforeBytes': shutil.disk_usage('/tmp').free, 'actions': [], 'skipped': []}
    running = subprocess.check_output(['ps', '-axo', 'command='], text=True).splitlines()
    inventory = json.loads(subprocess.check_output(['xcrun', 'simctl', 'list', 'devices', '--json'], text=True)) if simulators else {'devices': {}}
    states = {d['udid']: d['state'] for rows in inventory['devices'].values() for d in rows}
    devices = Path.home() / 'Library/Developer/CoreSimulator/Devices'
    caches = []
    for value in build_caches:
        original = Path(value).expanduser()
        cache = original.resolve()
        owned = cache.is_relative_to((Path.home() / 'Library/Caches/TaskfoldBuild').resolve()) or (cache.parent == Path('/private/tmp') and cache.name.startswith('taskfold-'))
        marked = (cache / 'DailyProject/Taskfold.xcodeproj').is_dir() or any(cache.glob('taskfold-daily-*.json'))
        if not owned or not marked or original.is_symlink():
            raise ValueError('Not a marked Taskfold build cache: ' + str(cache))
        caches.append((cache, {str(cache), str(original.absolute())}))
    for device in simulators:
        if states.get(device) != 'Shutdown':
            report['skipped'].append({'device': device, 'reason': 'Not a known shutdown Simulator'}); continue
        root = devices / device / 'data/Library/Application Support/PRBPosterExtensionDataStore'
        for cache in root.glob('*/Extensions/*/descriptors/*/versions/*/scratch/SnapshotCache.cachedb'):
            if cache.is_symlink() or not cache.resolve().is_relative_to(root.resolve()):
                raise ValueError('Unexpected wallpaper scratch path')
            report['actions'].append({'path': str(cache), 'kind': 'wallpaperScratch', 'allocatedBytes': allocated(cache)})
            if apply: shutil.rmtree(cache)
    for cache, aliases in caches:
        # Another project's compiler must not suppress cleanup indefinitely.
        # Our builders always pass absolute cache/input paths to Xcode/Swift.
        compiling = any(line.strip() and Path(line.strip().split(maxsplit=1)[0]).name in ('xcodebuild', 'swift-frontend', 'swiftc', 'clang')
                        and any(alias in line for alias in aliases) for line in running)
        if compiling or any(line.strip().startswith(str(cache) + '/') and '.app/' in line for line in running):
            report['skipped'].append({'cache': str(cache), 'reason': 'Compiler or cache app still running'}); continue
        # Prune cheap generated caches before expensive app objects. Between
        # the soft and hard floors, stop once the complete cache fits its budget;
        # crossing the soft floor alone must not force a full app rebuild.
        candidates = [cache / name for name in ['Index.noindex', 'CompilationCache.noindex', 'SDKExplicitPrecompiledModules', 'ModuleCache.noindex', 'SDKStatCaches.noindex', 'Build/Intermediates.noindex']]
        metadata = cache / 'Build/Intermediates.noindex/XCBuildData'
        for path in candidates + [metadata]:
            if path.is_symlink() or (path.exists() and not path.resolve().is_relative_to(cache)):
                raise ValueError('Unexpected compiler cache link')
        sizes = {path: allocated(path) for path in candidates}
        initial_total = allocated(cache)
        total = initial_total
        free = shutil.disk_usage(cache).free
        healthy = free >= 30 * 1024**3
        critical = free < 20 * 1024**3
        budget = 768 * 1024**2
        transient = {'Index.noindex', 'CompilationCache.noindex'}
        retired = []
        for path in candidates:
            if not critical and total <= budget and (healthy or path.name not in transient): break
            if path.exists():
                report['actions'].append({'path': str(path), 'kind': 'completedCompilerCache', 'allocatedBytes': sizes[path]})
                if apply: shutil.rmtree(path)
                retired.append(path)
                total -= sizes[path]
        # Xcode's saved dependency plan can still reference a removed module's
        # .scan file. Retire that generated plan too, while keeping app objects,
        # products and test evidence. The next build must rescan its inputs.
        if any(path.name != 'Index.noindex' for path in retired) and not any(metadata.is_relative_to(path) for path in retired) and metadata.exists():
            size = allocated(metadata)
            report['actions'].append({'path': str(metadata), 'kind': 'completedBuildMetadata', 'allocatedBytes': size})
            if apply: shutil.rmtree(metadata)
            total -= size
        reason = ('Reusable compiler cache within 768 MiB budget' if total <= budget else 'Protected products/evidence exceed budget; reviewed cleanup needed') if apply or initial_total <= budget else 'Dry-run budget trim; no files removed'
        if not apply and retired:
            reason = 'Dry-run cache trim; no files removed'
        elif critical and total <= budget:
            reason = 'Regenerable caches retired below the 20 GiB floor; protected products retained'
        report['skipped'].append({'cache': str(cache), 'reason': reason, 'allocatedBytes': total if apply else initial_total, 'projectedAllocatedBytes': total, 'within768MiB': total <= budget,
                                  'storagePressure': 'critical' if critical else 'normal' if healthy else 'constrained', 'budgetBytes': budget})
    report['freeAfterBytes'] = shutil.disk_usage('/tmp').free
    report['actualFreeChangeBytes'] = report['freeAfterBytes'] - report['freeBeforeBytes']
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--simulator', action='append', default=[], help='Explicit Taskfold test device; only wallpaper scratch while shutdown')
    parser.add_argument('--build-cache', action='append', default=[], help='Explicit completed marked Taskfold derived-data directory')
    parser.add_argument('--apply', action='store_true', help='Remove only the enumerated generated caches')
    parser.add_argument('--report', type=Path, help='Write a concise audit outside app data')
    args = parser.parse_args()
    target = args.report.expanduser().resolve() if args.report else None
    if target and target.exists(): raise SystemExit('Preserve the previous cleanup report; choose a new report path')
    report = finish(args.simulator, args.build_cache, args.apply)
    if target:
        target.write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report, indent=2))


if __name__ == '__main__':
    main()
