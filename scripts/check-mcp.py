#!/usr/bin/env python3
"""CLI integration regression: python3 scripts/check-mcp.py <MyVocab executable>."""
from pathlib import Path
from tempfile import TemporaryDirectory
import hashlib
import json
import subprocess
import sys
import time
import uuid

adapter = Path(__file__).with_name('myvocab-mcp.py')
with TemporaryDirectory(prefix='myvocab-mcp-test-') as tmp:
    root = Path(tmp)
    (root / 'decks').mkdir()
    (root / 'progress').mkdir()
    deck_id = str(uuid.uuid4()).upper()
    (root / 'decks' / (deck_id + '.json')).write_text(json.dumps({
        'id': deck_id, 'name': 'MCP fixture', 'cards': [{'front': 'bonjour', 'back': '你好', 'hint': ''}]}))
    now = time.time() - 978307200
    event = {'id': str(uuid.uuid4()).upper(), 'deck': deck_id, 'card': 'fixture', 'date': now, 'kind': {'grade': {'_0': 3}}}
    (root / 'progress' / (deck_id + '.jsonl')).write_text(json.dumps(event) + '\n')
    def manifest():
        return {str(p.relative_to(root)): (p.stat().st_mtime_ns, hashlib.sha256(p.read_bytes()).hexdigest())
                for p in root.rglob('*') if p.is_file()}
    before = manifest()
    requests = [
        {'id': 1, 'method': 'initialize', 'params': {'protocolVersion': '2025-11-25'}},
        {'method': 'notifications/initialized'}, {'id': 2, 'method': 'tools/list'},
        {'id': 3, 'method': 'tools/call', 'params': {'name': 'myvocab_recent_learning', 'arguments': {'days': 7}}},
        {'id': 4, 'method': 'tools/call', 'params': {'name': 'myvocab_recent_learning', 'arguments': {'days': 0}}},
        {'id': 5, 'method': 'tools/call', 'params': {'name': 'unknown'}}]
    result = subprocess.run(['python3', str(adapter), '--executable', sys.argv[1], '--data-dir', str(root)],
                            input='\n'.join(json.dumps(dict(jsonrpc='2.0', **r)) for r in requests) + '\n',
                            capture_output=True, text=True, check=True, timeout=60)
    replies = [json.loads(line) for line in result.stdout.splitlines()]
    assert len(replies) == 5, result.stdout
    assert replies[0]['result']['protocolVersion'] == '2025-11-25'
    assert replies[1]['result']['tools'][0]['annotations']['readOnlyHint'] is True
    report = json.loads(replies[2]['result']['content'][0]['text'])
    assert report['reviewCount'] == report['todayReviewCount'] == 1, report
    assert report['events'][0]['grade'] == 3
    assert report['events'][0]['kind'] == 'grade'
    assert report['diagnostics'] == [], report
    assert replies[3]['result']['isError'] and replies[4]['result']['isError']
    assert manifest() == before, 'Read-only query changed data'
print('PASS: MCP handshake, discovery, recent learning, invalid input, unknown tool, no writes')
