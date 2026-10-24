"""One synthetic loopback request for Android SDK acceptance; no filesystem API."""
import json
from http.server import BaseHTTPRequestHandler,HTTPServer
class Probe(BaseHTTPRequestHandler):
    def log_message(self,*args):pass
    def do_GET(self):
        if self.path!='/probe':self.send_error(404);return
        raw=json.dumps({'probe':'synthetic-companion','authorization':bool(self.headers.get('Authorization')),'cookie':bool(self.headers.get('Cookie'))}).encode()
        self.send_response(200);self.send_header('Content-Type','application/json');self.send_header('Content-Length',str(len(raw)));self.end_headers();self.wfile.write(raw)
if __name__=='__main__':
    server=HTTPServer(('127.0.0.1',8765),Probe);server.timeout=300
    print('Synthetic companion ready on loopback',flush=True);server.handle_request();server.server_close();print('Synthetic probe complete',flush=True)
