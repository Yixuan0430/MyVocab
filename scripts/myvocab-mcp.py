#!/usr/bin/env python3
import argparse
import json
import subprocess
import sys

SUPPORTED_PROTOCOLS = ('2024-11-05', '2025-03-26', '2025-06-18', '2025-11-25')

parser = argparse.ArgumentParser()
parser.add_argument('--executable', required=True)
parser.add_argument('--data-dir', required=True)
config = parser.parse_args()


def reply(ident, result=None, error=None):
    message = {'jsonrpc': '2.0', 'id': ident}
    message['error' if error else 'result'] = error or result
    print(json.dumps(message, ensure_ascii=False), flush=True)


def dict_or_empty(value):
    return value if isinstance(value, dict) else {}


for line in sys.stdin:
    if not line.strip():
        continue
    request = None
    try:
        request = json.loads(line)
        if not isinstance(request, dict):
            reply(None, error={'code': -32600, 'message': '无效的请求格式'})
            continue
        if 'id' not in request:
            continue
        ident = request['id']
        method = request.get('method')
        params = dict_or_empty(request.get('params'))
        if method == 'initialize':
            requested = params.get('protocolVersion')
            protocol = requested if requested in SUPPORTED_PROTOCOLS else '2025-11-25'
            reply(
                ident,
                {
                    'protocolVersion': protocol,
                    'capabilities': {'tools': {}},
                    'serverInfo': {'name': 'MyVocab', 'version': '1.1.0'},
                },
            )
        elif method == 'ping':
            reply(ident, {})
        elif method == 'tools/list':
            reply(
                ident,
                {
                    'tools': [
                        {
                            'name': 'myvocab_recent_learning',
                            'description': '只读查询本机最近学习记录、今日复习次数和各词库待复习概况。grade 为 1忘记/2模糊/3记住，seed 为旧进度迁移，不计入复习次数。',
                            'inputSchema': {
                                'type': 'object',
                                'properties': {
                                    'days': {'type': 'integer', 'minimum': 1, 'maximum': 365}
                                },
                                'additionalProperties': False,
                            },
                            'annotations': {
                                'readOnlyHint': True,
                                'destructiveHint': False,
                                'openWorldHint': False,
                            },
                        }
                    ]
                },
            )
        elif method == 'tools/call':
            if params.get('name') != 'myvocab_recent_learning':
                raise ValueError('未知查询')
            arguments = dict_or_empty(params.get('arguments'))
            days = arguments.get('days', 7)
            if type(days) is not int or not 1 <= days <= 365:
                raise ValueError('days 必须为 1–365 的整数')
            result = subprocess.run(
                [
                    config.executable,
                    '--learning-report',
                    '--data-dir',
                    config.data_dir,
                    '--no-migration',
                    '--no-sync',
                    '--days',
                    str(days),
                ],
                capture_output=True,
                text=True,
                timeout=30,
                check=True,
            )
            report = json.loads(result.stdout)
            reply(ident, {'content': [{'type': 'text', 'text': json.dumps(report, ensure_ascii=False)}]})
        else:
            reply(ident, error={'code': -32601, 'message': '不支持的方法'})
    except Exception as error:
        if isinstance(request, dict) and 'id' in request:
            if request.get('method') == 'tools/call':
                reply(request['id'], {'isError': True, 'content': [{'type': 'text', 'text': str(error)}]})
            else:
                reply(request['id'], error={'code': -32603, 'message': str(error)})
        else:
            reply(None, error={'code': -32700, 'message': '无法解析请求'})
