"""Local PC viewer: UDP -> validated full frames -> localhost HTTP. Python stdlib only."""
import argparse, json, mimetypes, socket, threading, time, webbrowser, secrets, os, io, base64
from pathlib import Path
from http.server import ThreadingHTTPServer,BaseHTTPRequestHandler
from urllib.parse import urlparse,parse_qs
from protocol import Receiver,packets
from studio_control import BoardControl
from recognition import Recognition
from mobile_access import MobileAccess,PAIR_PAGE
ROOT=Path(__file__).resolve().parent
CONFIG=json.loads((ROOT/'network_config.json').read_text(encoding='utf-8'))

def make_server(http_port=8765,udp_port=18500,source_ip=None,demo=False,lan_ip=None):
    receiver=Receiver(source_ip); lock=threading.Lock();stop=threading.Event()
    access=MobileAccess(lan_ip or CONFIG['pc_ip'])
    pair_frames=[None];jpeg_cache={};jpeg_lock=threading.Lock()
    completed={0:{},1:{}};pair_epoch=[receiver.epoch]
    udp=socket.socket(socket.AF_INET,socket.SOCK_DGRAM)
    udp.setsockopt(socket.SOL_SOCKET,socket.SO_RCVBUF,8*1024*1024)
    udp.bind(('127.0.0.1' if demo else '0.0.0.0',udp_port));udp.settimeout(.2)
    board=BoardControl(board_ip=source_ip or CONFIG['board_ip'],broadcast=CONFIG['broadcast'])
    recognizer=Recognition(receiver,lock,board)
    token=secrets.token_urlsafe(32)
    def listen():
        while not stop.is_set():
            try:data,addr=udp.recvfrom(2048)
            except socket.timeout:
                with lock:receiver.expire()
                continue
            except OSError:break
            if data.startswith(b'M7ST'):
                if not demo:board.feed(data,addr)
                continue
            with lock:
                complete=receiver.feed(data,addr)
                if receiver.epoch!=pair_epoch[0]:
                    pair_epoch[0]=receiver.epoch;pair_frames[0]=None
                    completed[0].clear();completed[1].clear()
                if complete:
                    for stream in (0,1):
                        f=receiver.latest.get(stream)
                        if not f:continue
                        key=tuple(f[k] for k in ('epoch','frame_id','session','width','height','format','demo'))
                        completed[stream][key]=f
                        while len(completed[stream])>4:completed[stream].pop(next(iter(completed[stream])))
                    common=completed[0].keys() & completed[1].keys()
                    if common:
                        key=max(common,key=lambda k:max(completed[i][k]['revision'] for i in (0,1)))
                        pair_frames[0]=(completed[0][key],completed[1][key])
    class Handler(BaseHTTPRequestHandler):
        def log_message(self,*args):pass
        def send(self,code,data=b'',kind='application/octet-stream',headers=None):
            self.send_response(code);self.send_header('Content-Type',kind)
            self.send_header('Content-Length',str(len(data)));self.send_header('Cache-Control','no-store')
            self.send_header('X-Content-Type-Options','nosniff')
            self.send_header('X-Frame-Options','DENY')
            self.send_header('Referrer-Policy','same-origin')
            for k,v in (headers or {}).items():self.send_header(k,str(v))
            self.end_headers()
            try:self.wfile.write(data)
            except (BrokenPipeError,ConnectionResetError):pass
        def valid_peer(self):
            return access.host_allowed(self.headers.get('Host'),self.server.server_port) and access.peer_allowed(self.client_address[0])
        def authorized(self):
            return access.authenticated(self.client_address[0],self.headers.get('Cookie'))
        def do_POST(self):
            origin=self.headers.get('Origin')
            expected='http://'+self.headers.get('Host','')
            if not self.valid_peer() or (origin and origin!=expected):
                self.send(403,b'Forbidden');return
            if self.path=='/pair':
                try:
                    size=int(self.headers.get('Content-Length','0'))
                    if not 1<=size<=128:raise ValueError()
                    pin=parse_qs(self.rfile.read(size).decode()).get('pin',[''])[0]
                    result=access.pair(self.client_address[0],pin)
                except (ValueError,UnicodeError):result=400
                if result==200:
                    self.send(303,headers={'Location':'/','Set-Cookie':'M7Mobile='+access.session+'; Path=/; HttpOnly; SameSite=Strict'});return
                note='尝试过多，请一分钟后重试。' if result==429 else '连接码不正确，请返回重试。'
                self.send(result,(note+'<br><a href="/">返回连接页</a>').encode(),'text/html; charset=utf-8');return
            if not self.authorized() or self.headers.get('X-Studio-Token')!=token:
                self.send(403,b'Forbidden');return
            try:
                size=int(self.headers.get('Content-Length','0'))
                if size<2 or size>2048:raise ValueError('Invalid request')
                payload=json.loads(self.rfile.read(size))
                if not isinstance(payload,dict):raise ValueError('Invalid request')
                if self.path=='/api/shutdown':
                    if not access.local(self.client_address[0]):self.send(403);return
                    self.send(200,b'{"ok":true}','application/json')
                    stop.set();threading.Thread(target=http.shutdown,daemon=True).start();return
                if demo:raise ValueError('模拟模式不能控制实体板或开启识别')
                if self.path=='/api/style':board.select(payload.get('style'), 'button')
                elif self.path=='/api/recognition':recognizer.configure(payload.get('kind'),payload.get('enabled'),payload.get('device'))
                else:self.send(404);return
                self.send(200,json.dumps({'ok':True,'recognition':recognizer.status(),'control':board.status()},ensure_ascii=False).encode(),'application/json; charset=utf-8');return
            except (ValueError,TypeError) as e:
                self.send(400,json.dumps({'error':str(e)},ensure_ascii=False).encode(),'application/json; charset=utf-8')
        def do_GET(self):
            path=urlparse(self.path)
            if not self.valid_peer():self.send(403,b'Forbidden');return
            if not self.authorized():
                if path.path=='/':self.send(200,PAIR_PAGE.encode(),'text/html; charset=utf-8')
                else:self.send(401,b'Pair this phone first','text/plain')
                return
            if path.path=='/api/instance':
                data={'app':'M7_STUDIO','release':'R6.1','pid':os.getpid()}
                if access.local(self.client_address[0]):data['root']=str(ROOT)
                self.send(200,json.dumps(data).encode(),'application/json');return
            if path.path=='/api/status':
                with lock:d=receiver.snapshot()
                d.update({'mode':'demo' if demo else 'live','udp_port':udp.getsockname()[1],
                          'expected_source_ip':source_ip,'simulator_running':demo,'control':board.status(),'recognition':recognizer.status(),'control_token':token,'mobile':access.status(access.local(self.client_address[0]),self.server.server_port)})
                self.send(200,json.dumps(d).encode(),'application/json; charset=utf-8');return
            if path.path=='/api/diagnostics':
                with lock:video=receiver.snapshot()
                data=recognizer.diagnostics();data['video']=video;data['control']=board.status()
                self.send(200,json.dumps(data,ensure_ascii=False,indent=2).encode(),'application/json; charset=utf-8');return
            if path.path=='/api/microphones':
                self.send(200,json.dumps(recognizer.devices(),ensure_ascii=False).encode(),'application/json; charset=utf-8');return
            if path.path=='/api/frame-pair':
                with lock:pair=pair_frames[0]
                if not pair or time.monotonic()-min(f['received_at'] for f in pair)>1.5:self.send(204);return
                a,b=pair;key=str(a['revision'])+':'+str(b['revision'])
                if parse_qs(path.query).get('after',[''])[0]==key:self.send(204);return
                self.send(200,a['data']+b['data'],headers={
                    'X-Pair-Key':key,'X-Pair-Split':len(a['data']),
                    'X-Frame-Width':a['width'],'X-Frame-Height':a['height'],
                    'X-Pixel-Format':a['format'],'X-Frame-ID':a['frame_id'],
                    'X-Frame-Session':a['session'],'X-Frame-Demo':int(a['demo'])});return
            if path.path=='/api/mobile-frame':
                with lock:pair=pair_frames[0]
                if not pair or time.monotonic()-min(f['received_at'] for f in pair)>1.5:self.send(204);return
                key=str(pair[0]['revision'])+':'+str(pair[1]['revision'])
                if parse_qs(path.query).get('after',[''])[0]==key:self.send(204);return
                with jpeg_lock:
                    if jpeg_cache.get('key')!=key:
                        from PIL import Image
                        payload={'key':key,'width':pair[0]['width'],'height':pair[0]['height'],
                            'id':pair[0]['frame_id'],'session':pair[0]['session'],'demo':pair[0]['demo'],'images':[]}
                        for f in pair:
                            image=Image.frombytes('RGB',(f['width'],f['height']),f['data'],'raw','BGR;16') if f['format']==1 else Image.frombytes('RGB',(f['width'],f['height']),f['data'])
                            buf=io.BytesIO();image.save(buf,format='JPEG',quality=82)
                            payload['images'].append(base64.b64encode(buf.getvalue()).decode('ascii'))
                        jpeg_cache.update(key=key,data=json.dumps(payload).encode())
                    data=jpeg_cache['data']
                self.send(200,data,'application/json');return
            if path.path in ('/api/frame/0','/api/frame/1'):
                stream=int(path.path[-1]);args=parse_qs(path.query)
                with lock:
                    f=receiver.latest.get(stream)
                    f=dict(f) if f else None
                if not f or time.monotonic()-f['received_at']>1.5:self.send(204);return
                if args.get('after',[''])[0]==str(f['revision']):self.send(204);return
                self.send(200,f['data'],headers={'X-Frame-Width':f['width'],'X-Frame-Height':f['height'],
                    'X-Pixel-Format':f['format'],'X-Frame-ID':f['frame_id'],'X-Frame-Revision':f['revision'],
                    'X-Frame-Session':f['session'],'X-Frame-Demo':int(f['demo'])});return
            files={'/':'index.html','/app.js':'app.js','/style.css':'style.css'}
            if path.path not in files:self.send(404,b'Not found','text/plain');return
            p=ROOT/'web'/files[path.path]
            self.send(200,p.read_bytes(),{'html':'text/html; charset=utf-8','js':'application/javascript; charset=utf-8','css':'text/css; charset=utf-8'}[p.suffix[1:]])
    try:http=ThreadingHTTPServer(('127.0.0.1',http_port),Handler)
    except Exception:recognizer.close();board.close();udp.close();raise
    http.daemon_threads=True
    threads=[threading.Thread(target=listen,daemon=True)]
    if demo:
        def simulate():
            sock=socket.socket(socket.AF_INET,socket.SOCK_DGRAM);session=secrets.randbits(32);fid=0;w,h=320,180
            next_frame=time.monotonic()
            try:
                while not stop.is_set():
                    raw=bytearray(w*h*2);styled=bytearray(w*h*2)
                    for y in range(h):
                        for x in range(w):
                            rr=(x+fid*4)%256;gg=y*255//(h-1);bb=(x+y+fid*2)%256
                            c=((rr>>3)<<11)|((gg>>2)<<5)|(bb>>3);i=2*(y*w+x)
                            raw[i]=c&255;raw[i+1]=c>>8
                            edge=x%32==0 or y%30==0
                            sr=0 if edge else (rr//64)*85;sg=0 if edge else (gg//64)*85;sb=0 if edge else (bb//64)*85
                            q=((sr>>3)<<11)|((sg>>2)<<5)|(sb>>3);styled[i]=q&255;styled[i+1]=q>>8
                    for stream,data in enumerate((raw,styled)):
                        for packet in packets(data,w,h,fid,stream=stream,session=session,demo=True):
                            sock.sendto(packet,('127.0.0.1',udp.getsockname()[1]))
                    fid=(fid+1)&0xffffffff;next_frame+=1/15
                    if next_frame<time.monotonic()-.2:next_frame=time.monotonic()
                    stop.wait(max(0,next_frame-time.monotonic()))
            finally:sock.close()
        threads.append(threading.Thread(target=simulate,daemon=True))
    def lan_listener():
        lan=None
        try:
            while not stop.is_set():
                try:lan=ThreadingHTTPServer((access.lan_ip,http.server_port),Handler)
                except OSError:
                    access.error='等待电脑连接板卡路由器并使用 '+access.lan_ip
                    stop.wait(3);continue
                lan.daemon_threads=True;lan.timeout=.3;access.ready=True;access.error='手机连接同一路由器后，打开地址并输入连接码'
                while not stop.is_set():lan.handle_request()
        finally:
            access.ready=False
            if lan:lan.server_close()
    if lan_ip:threads.append(threading.Thread(target=lan_listener,daemon=True))
    def cleanup():
        stop.wait();recognizer.close();board.close()
    threads.append(threading.Thread(target=cleanup,daemon=True))
    for t in threads:t.start()
    return http,udp,stop,receiver,lock

def main():
    ap=argparse.ArgumentParser(description='M7 local PC and paired LAN phone viewer')
    ap.add_argument('--http-port',type=int,default=8765);ap.add_argument('--udp-port',type=int,default=18500)
    ap.add_argument('--source-ip');ap.add_argument('--demo',action='store_true');ap.add_argument('--open',action='store_true')
    ap.add_argument('--lan-ip',help='Bind this PC LAN IPv4 as a second listener; localhost remains available')
    a=ap.parse_args()
    if a.demo and a.source_ip:ap.error('--demo cannot use --source-ip')
    try:http,udp,stop,_,_=make_server(a.http_port,a.udp_port,a.source_ip or (None if a.demo else CONFIG['board_ip']),a.demo,a.lan_ip)
    except OSError as e:raise SystemExit('Cannot start (port may already be in use): '+str(e))
    url='http://127.0.0.1:'+str(http.server_port)
    print(('SIMULATION ONLY - NO BOARD DATA' if a.demo else 'LIVE - WAITING FOR FPGV/1 OR FPGV/2 FPGA DATA'),flush=True)
    print('M7 R6.1 blue-white studio. Viewer:',url,' UDP:',udp.getsockname()[1],flush=True)
    if a.lan_ip:print('Phone: http://'+a.lan_ip+':'+str(http.server_port)+' (pairing code is in PC page)',flush=True)
    print('Use the M7 Ethernet experiment BIT; older HDMI-only BITs cannot send. Ctrl+C to stop.',flush=True)
    if a.open:webbrowser.open(url)
    try:http.serve_forever(poll_interval=.2)
    except KeyboardInterrupt:pass
    finally:stop.set();http.server_close();udp.close()
if __name__=='__main__':main()
