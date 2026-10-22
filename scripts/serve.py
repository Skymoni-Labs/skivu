"""Loopback-only static preview. No proxy, upload handler or business API."""
import argparse
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from functools import partial

class Handler(SimpleHTTPRequestHandler):
    def end_headers(self):
        self.send_header('Cache-Control', 'no-cache')
        self.send_header('X-Content-Type-Options', 'nosniff')
        super().end_headers()

if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--port', type=int, default=18781)
    parser.add_argument('--directory', required=True)
    args = parser.parse_args()
    server = ThreadingHTTPServer(('127.0.0.1', args.port), partial(Handler, directory=args.directory))
    print(f'ski ready at http://127.0.0.1:{args.port}/', flush=True)
    server.serve_forever()
