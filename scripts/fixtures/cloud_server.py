"""Local HTTP fixtures for provider streams, retries, cancellation, and parallel calls."""
import json
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        model = body.get('model', self.path.split('models/')[-1].split(':')[0])
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
        if model == 'reject-stream':
            if body.get('stream'):
                self.send_response(400)
                self.end_headers()
                return
            data = json.dumps({'choices': [{'message': {'content': 'Hello world.'}}],
                               'usage': {'prompt_tokens': 100, 'completion_tokens': 20}}).encode()
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
        if model == 'cancel':
            time.sleep(0.4)
        if 'streamGenerateContent' in self.path:
            events = [{'candidates': [{'content': {'parts': [{'text': 'Hello'}]}}]},
                      {'candidates': [{'content': {'parts': [{'text': ' world.'}]}, 'finishReason': 'STOP'}],
                       'usageMetadata': {'promptTokenCount': 100, 'candidatesTokenCount': 20}}]
        elif self.path.endswith('/messages'):
            events = [{'type': 'message_start', 'message': {'usage': {'input_tokens': 100, 'output_tokens': 1}}},
                      {'type': 'content_block_delta', 'delta': {'type': 'text_delta', 'text': 'Hello'}},
                      {'type': 'content_block_delta', 'delta': {'type': 'text_delta', 'text': ' world.'}},
                      {'type': 'message_delta', 'usage': {'output_tokens': 20}}, {'type': 'message_stop'}]
        else:
            events = [{'choices': [{'delta': {'content': 'Hello'}}]},
                      {'choices': [{'delta': {'content': ' world.'}, 'finish_reason': 'stop'}]},
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
