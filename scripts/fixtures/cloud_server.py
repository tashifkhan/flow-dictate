"""Local HTTP fixtures for provider streams, retries, cancellation, and parallel calls."""
import json
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


class Handler(BaseHTTPRequestHandler):
    requests = []

    def log_message(self, *_):
        pass

    def do_GET(self):
        data = json.dumps(self.requests).encode()
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        model = body.get('model', self.path.split('models/')[-1].split(':')[0])
        streamed = bool(body.get('stream') or 'streamGenerateContent' in self.path)
        self.requests.append({'model': model, 'stream': streamed, 'path': self.path,
                              'accept': self.headers.get('Accept', ''), 'usageOptions': 'stream_options' in body,
                              'streamField': body.get('stream')})
        if model == 'reject-usage-options' and 'stream_options' in body:
            self.send_response(400)
            self.end_headers()
            return
        if model == 'reject-reasoning' and 'reasoning_effort' in body:
            self.send_response(400)
            self.end_headers()
            return
        if model == 'multimodal-transcriber':
            parts = body.get('messages', [{}])[0].get('content', [])
            if not self.path.endswith('/chat/completions') or not any(p.get('type') == 'input_audio' for p in parts):
                self.send_response(400)
                self.end_headers()
                return
        if model == 'failed':
            self.send_response(429)
            self.end_headers()
            return
        if model in ['reject-stream', 'reject-stream-google', 'reject-stream-anthropic', 'ignore-stream', 'disabled-json']:
            if streamed and model != 'ignore-stream':
                self.send_response(501 if model == 'reject-stream' else 405 if model == 'reject-stream-google' else 400)
                self.end_headers()
                return
            if 'models/' in self.path:
                result = {'candidates': [{'content': {'parts': [{'text': 'Hello world.'}]}}]}
            elif self.path.endswith('/messages'):
                result = {'content': [{'type': 'text', 'text': 'Hello world.'}]}
            else:
                result = {'choices': [{'message': {'content': 'Hello world.'}}],
                          'usage': {'prompt_tokens': 100, 'completion_tokens': 20}}
            data = json.dumps(result).encode()
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Content-Length', str(len(data)))
            self.end_headers()
            self.wfile.write(data)
            return
        self.send_response(200)
        self.send_header('Content-Type', 'text/event-stream')
        self.end_headers()
        if model == 'slow':
            time.sleep(1.1)
        if model == 'preferred-slow':
            time.sleep(0.4)
        if model == 'cancel':
            time.sleep(0.4)
        if 'models/' in self.path:
            events = [{'candidates': [{'content': {'parts': [{'text': 'Hello'}]}}]},
                      {'candidates': [{'content': {'parts': [{'text': ' world.'}]}, 'finishReason': 'STOP'}],
                       'usageMetadata': {'promptTokenCount': 100, 'candidatesTokenCount': 20}}]
        elif self.path.endswith('/messages'):
            events = [{'type': 'message_start', 'message': {'usage': {'input_tokens': 100, 'output_tokens': 1}}},
                      {'type': 'content_block_delta', 'delta': {'type': 'text_delta', 'text': 'Hello'}},
                      {'type': 'content_block_delta', 'delta': {'type': 'text_delta', 'text': ' world.'}},
                      {'type': 'message_delta', 'usage': {'output_tokens': 20}}, {'type': 'message_stop'}]
        else:
            first, rest = 'Hello', ' world.'
            if model == 'alternate-fast':
                first, rest = 'world', ' Hello.'
            if model == 'strayed':
                first, rest = 'Invented', ' unrelated words.'
            if model == 'echo-input':
                first, rest = body['messages'][-1]['content'], ''
            if model == 'wrong-email':
                first, rest = 'wrong@example.com', ''
            events = [{'choices': [{'delta': {'content': first}}]},
                      {'choices': [{'delta': {'content': rest}, 'finish_reason': 'stop'}]},
                      {'choices': [], 'usage': {'prompt_tokens': 100, 'completion_tokens': 20}}, '[DONE]']
        try:
            for event in events:
                time.sleep(0.06)
                value = event if isinstance(event, str) else json.dumps(event)
                self.wfile.write(('data: ' + value + '\n\n').encode())
                self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            pass


server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
with open(sys.argv[1], 'w') as port_file:
    port_file.write(str(server.server_port))
server.serve_forever()
