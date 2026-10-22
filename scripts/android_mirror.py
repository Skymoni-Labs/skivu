"""Loopback Android preview for the Codex side panel; no model API proxy."""
import argparse
import json
import secrets
import subprocess
import threading
import time
from collections import deque
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HTML = r'''<!doctype html><html lang="zh-CN"><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Skivu · Android 模拟器</title>
<style>
*{box-sizing:border-box}body{margin:0;background:#e9edf3;color:#344155;font:13px system-ui,sans-serif}
header{height:44px;display:flex;align-items:center;justify-content:space-between;padding:0 14px;background:#fff9;border-bottom:1px solid #dce2eb}
strong{font-weight:600}small{color:#8491a3}main{height:calc(100vh - 44px);display:grid;place-items:center;padding:8px}
img{display:block;max-height:calc(100vh - 60px);max-width:100%;width:auto;height:auto;box-shadow:0 8px 30px #26394b18;border-radius:18px;touch-action:none;user-select:none;background:#dce4f0}
button{border:0;border-radius:8px;background:#e8edf4;color:#344155;padding:5px 10px;cursor:pointer}
#wait{position:fixed;bottom:14px;background:#fffc;padding:5px 12px;border-radius:12px;color:#8491a3;pointer-events:none}
</style><header><strong>Android 模拟器</strong><span><small id="state">正在连接…</small> <button id="back">返回</button></span></header>
<main><img id="screen" alt="安卓模拟器实时画面" draggable="false"></main><div id="wait">正在等待安卓画面</div>
<script>
const image=document.querySelector('#screen'),state=document.querySelector('#state'),wait=document.querySelector('#wait');
const token='__TOKEN__',nativeWidth=__WIDTH__,nativeHeight=__HEIGHT__;
let active=true,pressed=null;
function frame(){if(!active)return;image.src='/stream.mjpeg?t='+Date.now()}
image.onload=()=>{wait.hidden=true;state.textContent='视频已同步'};
image.onerror=()=>{wait.hidden=false;state.textContent='等待设备';setTimeout(frame,1200)};
setInterval(async()=>{if(!active)return;try{const s=await(await fetch('/status')).json();wait.hidden=s.ready;state.textContent=s.ready?'实时视频已同步':'等待视频'}catch(e){}},2000);
document.addEventListener('visibilitychange',()=>{active=!document.hidden;if(active)frame()});
function point(e){const r=image.getBoundingClientRect();return [Math.round((e.clientX-r.left)*nativeWidth/r.width),Math.round((e.clientY-r.top)*nativeHeight/r.height)]}
async function input(body){try{await fetch('/input',{method:'POST',headers:{'Content-Type':'application/json','X-Preview-Token':token},body:JSON.stringify(body)})}catch(e){}}
image.onpointerdown=e=>{if(!image.naturalWidth)return;image.setPointerCapture(e.pointerId);pressed={point:point(e),time:Date.now()};e.preventDefault()};
image.onpointerup=e=>{if(!pressed)return;const end=point(e),start=pressed;pressed=null;const moved=Math.hypot(end[0]-start.point[0],end[1]-start.point[1])>15;input({kind:moved?'swipe':'tap',from:start.point,to:end,duration:Math.min(900,Math.max(100,Date.now()-start.time))});e.preventDefault()};
image.onpointercancel=()=>{pressed=null};
document.querySelector('#back').onclick=()=>input({kind:'back'});
frame();
</script></html>'''


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--device', default='emulator-5554')
    parser.add_argument('--port', type=int, default=18771)
    parser.add_argument('--adb', default='E:/DevTools/Android/Sdk/platform-tools/adb.exe')
    parser.add_argument('--ffmpeg', default='D:/CodexBuilds/ski-independent-ui/preview-python/imageio_ffmpeg/binaries/ffmpeg-win-x86_64-v7.1.exe')
    args = parser.parse_args()
    adb = [args.adb, '-s', args.device]
    token = secrets.token_urlsafe(32)
    geometry = subprocess.check_output(adb + ['shell', 'wm', 'size'], text=True, creationflags=subprocess.CREATE_NO_WINDOW).strip().split()[-1].split('x')
    native_width, native_height = map(int, geometry)
    frame = {'jpeg': None, 'index': 0, 'times': deque(maxlen=80)}
    ready = threading.Condition()
    command_lock = threading.Lock()

    def capture():
        while True:
            recorder = decoder = None
            try:
                recorder = subprocess.Popen(adb + ['exec-out', 'screenrecord', '--output-format=h264', '--size', '540x1200', '--bit-rate', '2M', '--time-limit', '0', '-'], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, creationflags=subprocess.CREATE_NO_WINDOW)
                decoder = subprocess.Popen([args.ffmpeg, '-hide_banner', '-loglevel', 'error', '-flags', 'low_delay', '-probesize', '32', '-analyzeduration', '0', '-f', 'h264', '-i', 'pipe:0', '-an', '-fps_mode', 'passthrough', '-threads', '1', '-f', 'image2pipe', '-vcodec', 'mjpeg', '-q:v', '5', '-flush_packets', '1', 'pipe:1'], stdin=recorder.stdout, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, creationflags=subprocess.CREATE_NO_WINDOW)
                recorder.stdout.close()
                buffer = bytearray()
                while True:
                    part = decoder.stdout.read1(65536)
                    if not part:
                        break
                    buffer.extend(part)
                    while True:
                        start = buffer.find(b'\xff\xd8')
                        end = buffer.find(b'\xff\xd9', max(0, start))
                        if start < 0 or end < 0:
                            break
                        image = bytes(buffer[start:end + 2])
                        del buffer[:end + 2]
                        with ready:
                            frame['jpeg'] = image
                            frame['index'] += 1
                            frame['times'].append(time.monotonic())
                            ready.notify_all()
            except (OSError, subprocess.SubprocessError):
                pass
            finally:
                for process in (decoder, recorder):
                    if process is not None and process.poll() is None:
                        process.terminate()
            time.sleep(1)

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def send(self, code, data, content_type):
            self.send_response(code)
            self.send_header('Content-Type', content_type)
            self.send_header('Content-Length', str(len(data)))
            self.send_header('Cache-Control', 'no-store')
            self.send_header('X-Content-Type-Options', 'nosniff')
            self.send_header('Referrer-Policy', 'no-referrer')
            self.end_headers()
            try:
                self.wfile.write(data)
            except (BrokenPipeError, ConnectionResetError):
                pass

        def do_GET(self):
            if self.headers.get('Host') != f'127.0.0.1:{args.port}':
                return self.send(403, b'', 'text/plain')
            if self.path.split('?')[0] == '/':
                return self.send(200, HTML.replace('__TOKEN__', token).replace('__WIDTH__', str(native_width)).replace('__HEIGHT__', str(native_height)).encode(), 'text/html; charset=utf-8')
            if self.path == '/status':
                times = list(frame['times'])
                fps = round((len(times) - 1) / (times[-1] - times[0])) if len(times) > 1 and times[-1] > times[0] else 0
                return self.send(200, json.dumps({'ready': bool(times), 'fps': fps, 'frames': frame['index']}).encode(), 'application/json')
            if self.path.split('?')[0] == '/stream.mjpeg':
                self.send_response(200)
                self.send_header('Content-Type', 'multipart/x-mixed-replace; boundary=skivu')
                self.send_header('Cache-Control', 'no-store')
                self.send_header('X-Content-Type-Options', 'nosniff')
                self.end_headers()
                seen = -1
                try:
                    while True:
                        with ready:
                            ready.wait_for(lambda: frame['index'] != seen and frame['jpeg'] is not None, timeout=5)
                            image, seen = frame['jpeg'], frame['index']
                        if image is None:
                            continue
                        self.wfile.write(b'--skivu\r\nContent-Type: image/jpeg\r\nContent-Length: ' + str(len(image)).encode() + b'\r\n\r\n' + image + b'\r\n')
                        self.wfile.flush()
                except (BrokenPipeError, ConnectionResetError, OSError):
                    pass
                return
            self.send(503, b'Android not ready', 'text/plain')

        def do_POST(self):
            origin = self.headers.get('Origin')
            if self.path != '/input' or self.headers.get('Host') != f'127.0.0.1:{args.port}' or origin not in (None, f'http://127.0.0.1:{args.port}') or not secrets.compare_digest(self.headers.get('X-Preview-Token', ''), token):
                return self.send(403, b'', 'text/plain')
            try:
                length = int(self.headers.get('Content-Length', '0'))
                if not 0 < length <= 2048:
                    raise ValueError()
                body = json.loads(self.rfile.read(length))
                # Only operate the app being developed, even if the user opens
                # another application while the screen remains visible.
                with command_lock:
                    activities = subprocess.check_output(adb + ['shell', 'dumpsys', 'activity', 'activities'], text=True, timeout=5, creationflags=subprocess.CREATE_NO_WINDOW)
                    current = next((line for line in activities.splitlines() if 'topResumedActivity=' in line), '')
                    if 'com.skyjjgw.independent.ski/' not in current:
                        return self.send(409, b'Open Skivu first', 'text/plain')
                    kind = body.get('kind')
                    if kind == 'back':
                        command = ['keyevent', '4']
                    else:
                        start, end = body['from'], body['to']
                        if len(start) != 2 or len(end) != 2 or any(type(x) is not int or not 0 <= x <= 6000 for x in start + end):
                            raise ValueError()
                        if kind == 'tap':
                            command = ['tap', *map(str, start)]
                        elif kind == 'swipe':
                            command = ['swipe', *map(str, start + end), str(max(100, min(900, int(body['duration']))))]
                        else:
                            raise ValueError()
                    subprocess.run(adb + ['shell', 'input', *command], check=True, timeout=5, creationflags=subprocess.CREATE_NO_WINDOW)
                self.send(200, b'{}', 'application/json')
            except (ValueError, KeyError, OSError, subprocess.SubprocessError):
                self.send(400, b'Invalid input', 'text/plain')

    server = ThreadingHTTPServer(('127.0.0.1', args.port), Handler)
    threading.Thread(target=capture, daemon=True).start()
    print(f'Android mirror: http://127.0.0.1:{args.port}/ ({args.device})', flush=True)
    server.serve_forever()


if __name__ == '__main__':
    main()
