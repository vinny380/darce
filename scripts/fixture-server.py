#!/usr/bin/env python3
"""Synthetic loopback origin for native browser integration checks."""
import argparse
import http.server
import json
import pathlib
import time
import urllib.parse

PAYLOAD = b'Native browser download fixture.\n' * 8192
SLOW_PAYLOAD = bytes(range(256)) * 32768

class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_GET(self):
        route = urllib.parse.urlsplit(self.path).path
        if route in ('/download', '/slow'):
            data = SLOW_PAYLOAD if route == '/slow' else PAYLOAD
            offset = 0
            byte_range = self.headers.get('Range', '')
            if byte_range.startswith('bytes='):
                try:
                    offset = int(byte_range[6:].split('-')[0])
                except ValueError:
                    self.send_error(416)
                    return
            if not 0 <= offset < len(data):
                self.send_error(416)
                return
            self.send_response(206 if offset else 200)
            self.send_header('Content-Type', 'application/octet-stream')
            self.send_header('Content-Disposition', 'attachment; filename="fixture.bin"')
            self.send_header('Accept-Ranges', 'bytes')
            self.send_header('ETag', '"synthetic-download-v1"')
            self.send_header('Last-Modified', 'Wed, 21 Oct 2026 07:28:00 GMT')
            self.send_header('Content-Length', str(len(data) - offset))
            if offset:
                self.send_header('Content-Range', f'bytes {offset}-{len(data)-1}/{len(data)}')
            self.end_headers()
            try:
                for start in range(offset, len(data), 65536):
                    self.wfile.write(data[start:start+65536])
                    self.wfile.flush()
                    if route == '/slow':
                        time.sleep(0.025)
            except (BrokenPipeError, ConnectionResetError):
                pass
            return
        html = b'''<!doctype html><html><head><title>Native Services Fixture</title></head>
<body><h1>Native Services Fixture</h1><p>Isolated local test origin.</p>
<a id="download" href="/download" download>Download fixture</a>
<p id="result">No action yet</p>
<button onclick="alert('Synthetic alert');result.textContent='alert closed'">Test Alert</button>
<button onclick="result.textContent='confirm: '+confirm('Synthetic confirm')">Test Confirm</button>
<button onclick="result.textContent='prompt: '+prompt('Synthetic prompt','sample')">Test Prompt</button>
<input aria-label="Choose synthetic file" type="file" onchange="result.textContent='file: '+this.files[0].name">
<script>window.fixtureReady = true;</script></body></html>'''
        self.send_response(200)
        self.send_header('Content-Type', 'text/html; charset=utf-8')
        self.send_header('Content-Length', str(len(html)))
        if route == '/seed':
            self.send_header('Set-Cookie', 'darce_fixture=retained; Max-Age=3600; SameSite=Lax; Path=/')
        self.end_headers()
        self.wfile.write(html)

parser = argparse.ArgumentParser()
parser.add_argument('--port-file', required=True)
args = parser.parse_args()
server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
pathlib.Path(args.port_file).write_text(json.dumps({'base_url': f'http://127.0.0.1:{server.server_port}'}))
server.serve_forever()
