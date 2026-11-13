#!/usr/bin/env python3
"""Read-only stdio MCP adapter. Never launches a GUI, syncs, or writes learning data."""
import argparse
import json
import subprocess
import sys

parser = argparse.ArgumentParser()
parser.add_argument('--executable', required=True)
parser.add_argument('--data-dir', required=True)
config = parser.parse_args()

def reply(ident, result=None, error=None):
    message = {'jsonrpc': '2.0', 'id': ident}
    message['error' if error else 'result'] = error or result
    print(json.dumps(message, ensure_ascii=False), flush=True)

for line in sys.stdin:
    request = None
    try:
        request = json.loads(line)
        if 'id' not in request:
            continue
        ident, method = request['id'], request.get('method')
        if method == 'initialize':
            reply(ident, {'protocolVersion': request.get('params', {}).get('protocolVersion') if request.get('params', {}).get('protocolVersion') in ('2024-11-05', '2025-03-26', '2025-06-18', '2025-11-25') else '2025-11-25', 'capabilities': {'tools': {}},
                          'serverInfo': {'name': 'MyVocab', 'version': '1.1.0'}})
        elif method == 'ping':
            reply(ident, {})
        elif method == 'tools/list':
            reply(ident, {'tools': [{'name': 'myvocab_recent_learning',
                'description': '只读查询本机最近学习记录、今日复习次数和各词库待复习概况。grade 为 1忘记/2模糊/3记住，seed 为旧进度迁移，不计入复习次数。',
                'inputSchema': {'type': 'object', 'properties': {'days': {'type': 'integer', 'minimum': 1, 'maximum': 365}}, 'additionalProperties': False},
                'annotations': {'readOnlyHint': True, 'destructiveHint': False, 'openWorldHint': False}}]})
        elif method == 'tools/call':
            if request.get('params', {}).get('name') != 'myvocab_recent_learning':
                raise ValueError('未知查询')
            days = request.get('params', {}).get('arguments', {}).get('days', 7)
            if type(days) is not int or not 1 <= days <= 365:
                raise ValueError('days 必须为 1–365 的整数')
            result = subprocess.run([config.executable, '--learning-report', '--data-dir', config.data_dir,
                                     '--no-migration', '--no-sync', '--days', str(days)],
                                    capture_output=True, text=True, timeout=30, check=True)
            report = json.loads(result.stdout)
            reply(ident, {'content': [{'type': 'text', 'text': json.dumps(report, ensure_ascii=False)}]})
        else:
            reply(ident, error={'code': -32601, 'message': '不支持的方法'})
    except Exception as error:
        if isinstance(request, dict) and 'id' in request:
            reply(request['id'], {'isError': True, 'content': [{'type': 'text', 'text': str(error)}]}) if request.get('method') == 'tools/call' else reply(request['id'], error={'code': -32603, 'message': str(error)})
        else:
            reply(None, error={'code': -32700, 'message': '无法解析请求'})
