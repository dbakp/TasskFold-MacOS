#!/usr/bin/env python3
"""Check compiled App Intents registrations used to restore widget configurations."""
import argparse
import json
import subprocess
from pathlib import Path


def metadata(bundle):
    candidates = [bundle / 'Metadata.appintents/extract.actionsdata',
                  bundle / 'Contents/Resources/Metadata.appintents/extract.actionsdata']
    path = next((p for p in candidates if p.is_file()), None)
    if path is None:
        raise ValueError(f'Missing compiled App Intents metadata in {bundle}')
    return json.loads(path.read_bytes())


def references(value):
    if isinstance(value, dict):
        for kind, field in [('entity', 'typeName'), ('linkEnumeration', 'identifier')]:
            if kind in value:
                yield kind, value[kind]['wrapper'][field]
        for child in value.values():
            yield from references(child)
    elif isinstance(value, list):
        for child in value:
            yield from references(child)


def parameter_contract(action):
    # The extractor emits supported coercions in different orders for different targets.
    parameters = []
    for parameter in action['parameters']:
        item = dict(parameter)
        item['resolvableInputTypes'] = sorted(item.get('resolvableInputTypes', []), key=lambda value: json.dumps(value, sort_keys=True))
        parameters.append(item)
    return parameters


def verify(app, extension):
    configs = {name: action for name, action in extension['actions'].items()
               if 'com.apple.link.systemProtocol.WidgetConfiguration' in action.get('systemProtocols', [])}
    if not configs:
        raise ValueError('No widget configuration intents found in the extension')
    entities, enums = set(), set()
    for name, action in configs.items():
        if name in app['actions'] and parameter_contract(action) != parameter_contract(app['actions'][name]):
            raise ValueError(f'{name}: app and extension parameter contracts differ')
        for kind, identifier in references(action['parameters']):
            collection = 'entities' if kind == 'entity' else 'enums'
            for target, data in [('extension', extension)]:
                values = data[collection]
                registered = values if isinstance(values, dict) else {v['identifier']: v for v in values}
                if identifier not in registered:
                    raise ValueError(f'{name}: {identifier} missing from {target} {collection} registration')
                if kind == 'entity':
                    query = registered[identifier]['defaultQueryIdentifier'].rsplit('.', 1)[-1]
                    if query not in data['queries']:
                        raise ValueError(f'{identifier}: {query} missing from {target} query registration')
            (entities if kind == 'entity' else enums).add(identifier)
    completion = 'CompleteWidgetTaskIntent'
    for target, data in [('app', app), ('extension', extension)]:
        if completion not in data['actions']:
            raise ValueError(f'{completion} missing from {target} registration')
    if parameter_contract(app['actions'][completion]) != parameter_contract(extension['actions'][completion]):
        raise ValueError('Widget completion parameter contracts differ between targets')
    return len(configs), len(entities), len(enums)


def team_identifier(bundle):
    result = subprocess.run(['codesign', '-dv', '--verbose=4', str(bundle)], capture_output=True, text=True)
    if result.returncode:
        raise ValueError(f'Cannot inspect signature in {bundle.name}')
    return next((line.split('=', 1)[1] for line in result.stderr.splitlines()
                 if line.startswith('TeamIdentifier=')), 'not set')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('app', type=Path, help='Built Taskfold.app bundle; no app launch occurs')
    parser.add_argument('--require-team', action='store_true', help='Also require matching signed app/widget teams before a provisioned host test')
    args = parser.parse_args()
    plugins = args.app / ('Contents/PlugIns' if (args.app / 'Contents').is_dir() else 'PlugIns')
    extensions = list(plugins.glob('TaskfoldWidgets.appex'))
    if len(extensions) != 1:
        parser.error(f'Expected one embedded TaskfoldWidgets.appex in {plugins}')
    try:
        configs, entities, enums = verify(metadata(args.app), metadata(extensions[0]))
        if args.require_team:
            teams = [team_identifier(args.app), team_identifier(extensions[0])]
            if any(team == 'not set' for team in teams):
                raise ValueError('App and widget signatures need a team identifier for provisioned host acceptance; this build cannot establish that prerequisite')
            if teams[0] != teams[1]:
                raise ValueError('App and widget signing teams differ')
    except (ValueError, KeyError) as error:
        parser.exit(1, f'Widget catalog verification failed: {error}\n')
    print(f'Verified {configs} widget configurations, {entities} entities, {enums} enums and app/widget completion metadata; installed behavior remains a separate check')


if __name__ == '__main__':
    main()
