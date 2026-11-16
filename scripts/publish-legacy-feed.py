#!/usr/bin/env python3
"""Keep the feed embedded in existing installations independent of the project Pages URL.

Publish to the domain repository's Hugo sources, so portfolio deployments retain it too.
Run after uploading the release assets and pushing the new appcast to main.
"""
import argparse
import base64
import json
from pathlib import Path
import subprocess
import xml.etree.ElementTree as ET

REPOSITORY = 'isaaclins/isaaclins.github.io'


def publish(feed: Path) -> None:
    content = feed.read_bytes()
    root = ET.fromstring(content)
    if not root.findall('./channel/item/enclosure'):
        raise ValueError('Refusing to publish an empty update feed')
    endpoint = f'repos/{REPOSITORY}/contents/static/spotiglass/appcast.xml'
    result = subprocess.run(['gh', 'api', endpoint + '?ref=main'], capture_output=True, text=True)
    payload = {'message': 'Keep the legacy music-player update feed available',
               'branch': 'main', 'content': base64.b64encode(content).decode()}
    if result.returncode == 0:
        existing = json.loads(result.stdout)
        if base64.b64decode(existing['content']) == content:
            print('Legacy update feed already matches')
            return
        payload['sha'] = existing['sha']
    elif 'HTTP 404' not in result.stderr:
        raise RuntimeError(result.stderr)
    subprocess.run(['gh', 'api', '--method', 'PUT', endpoint, '--input', '-'],
                   input=json.dumps(payload), text=True, check=True, stdout=subprocess.DEVNULL)
    print('Published legacy update feed to the domain Pages sources')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('feed', type=Path)
    publish(parser.parse_args().feed)
