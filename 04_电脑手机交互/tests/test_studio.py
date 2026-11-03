import unittest,json,sys,time,threading,urllib.request,urllib.error,struct,zlib,socket
from unittest.mock import patch
from pathlib import Path
r=Path(__file__).resolve().parents[1];sys.path.insert(0,str(r/'PC_VIEWER'))
from recognition import PalmGate,open_palm,voice_command
from studio_control import BoardControl,command_packet,parse_status
from server import make_server

def ack(seq,style):
 b=struct.pack('!4sIBBBB',b'M7ST',seq,style,1,style,0);return b+struct.pack('!I',zlib.crc32(b))
class FakeSocket:
 def __init__(self):self.sent=[]
 def sendto(self,data,dst):self.sent.append((data,dst))
 def close(self):pass
class StudioTests(unittest.TestCase):
 def test_palm_dwell_release_and_gap(self):
  g=PalmGate();events=[g.update(True,i/10) for i in range(31)]
  self.assertEqual(sum(events),1)
  for i in range(31,39):self.assertFalse(g.update(False,i/10))
  self.assertEqual(sum(g.update(True,i/10) for i in range(39,55)),1)
  g=PalmGate();self.assertFalse(g.update(True,0));self.assertFalse(g.update(True,2));self.assertFalse(g.update(True,2.2))
 def test_landmark_positive_and_closed_negative(self):
  p=json.loads((r/'tests/GESTURE_REFERENCE_RESULT.json').read_text())['hands'][0]['landmarks']
  self.assertTrue(open_palm(p))
  q=[x[:] for x in p]
  for tip in (8,12,16,20):q[tip]=q[0][:]
  self.assertFalse(open_palm(q));self.assertFalse(open_palm([]))
 def test_phrase(self):
  self.assertTrue(voice_command('切换 风格'));self.assertFalse(voice_command('今天的风格很好'));self.assertFalse(voice_command(''))
 def test_control_ack_not_send_success(self):
  b=BoardControl(clock=lambda:10);b.stop.set();b.thread.join();b.sock.close();b.sock=FakeSocket()
  self.addCleanup(b.close)
  with self.assertRaises(ValueError):b.select(1)
  self.assertFalse(b.feed(ack(1,0),('192.168.5.61',18500)))
  self.assertTrue(b.feed(ack(1,0),('192.168.5.60',18500)));self.assertTrue(b.select(1))
  self.assertEqual(b.status()['selected'],0);self.assertEqual(b.status()['pending'],1)
  seq=b.pending['sequence'];b.feed(ack(seq-1,0),('192.168.5.60',18500));self.assertIsNotNone(b.pending)
  b.feed(ack(seq,1),('192.168.5.60',18500));self.assertIsNone(b.pending);self.assertEqual(b.selected,1)
  self.assertFalse(b.select(None,'gesture')) # cooldown
  with self.assertRaises(ValueError):b.select(4)
 def test_status_crc(self):
  b=bytearray(ack(33,2));b[-1]^=1;self.assertIsNone(parse_status(b));self.assertIsNone(parse_status(b'M7ST'))
  p=command_packet(4,1);self.assertEqual(len(p),16);self.assertEqual(zlib.crc32(p[:12]),int.from_bytes(p[12:],'big'))
 def test_http_csrf_and_no_board(self):
  http,udp,stop,rx,lock=make_server(0,0);thread=threading.Thread(target=http.serve_forever,daemon=True);thread.start()
  try:
   url='http://127.0.0.1:'+str(http.server_port)
   state=json.load(urllib.request.urlopen(url+'/api/status'));self.assertFalse(state['recognition']['voice']);self.assertFalse(state['recognition']['gesture']);self.assertFalse(state['control']['connected'])
   def send(token,origin=None):
    headers={'Content-Type':'application/json','X-Studio-Token':token}
    if origin:headers['Origin']=origin
    req=urllib.request.Request(url+'/api/style',data=b'{"style":1}',headers=headers)
    try:urllib.request.urlopen(req);return 200
    except urllib.error.HTTPError as e:return e.code
   self.assertEqual(send('bad'),403);self.assertEqual(send(state['control_token'],'https://untrusted.example'),403);self.assertEqual(send(state['control_token']),400)
  finally:stop.set();http.shutdown();http.server_close();udp.close();thread.join()
 def test_http_udp_ack_roundtrip(self):
  import server
  with patch.object(server,'BoardControl',side_effect=lambda **kw:BoardControl(board_ip='127.0.0.1',broadcast='127.0.0.1')):
   http,udp,stop,rx,lock=make_server(0,0,source_ip='127.0.0.1')
  thread=threading.Thread(target=http.serve_forever,daemon=True);thread.start()
  emulator=socket.socket(socket.AF_INET,socket.SOCK_DGRAM);emulator.bind(('127.0.0.1',18501));emulator.settimeout(2)
  url='http://127.0.0.1:'+str(http.server_port)
  def status():return json.load(urllib.request.urlopen(url+'/api/status'))
  try:
   emulator.sendto(ack(0,0),('127.0.0.1',udp.getsockname()[1]))
   deadline=time.monotonic()+2
   while not status()['control']['connected'] and time.monotonic()<deadline:time.sleep(.02)
   st=status();self.assertTrue(st['control']['connected'])
   req=urllib.request.Request(url+'/api/style',data=b'{"style":2}',headers={'Content-Type':'application/json','X-Studio-Token':st['control_token']})
   self.assertTrue(json.load(urllib.request.urlopen(req))['ok'])
   payload,addr=emulator.recvfrom(100);self.assertEqual(payload[:4],b'M7CT');self.assertEqual(payload[8],2)
   self.assertEqual(zlib.crc32(payload[:12]),int.from_bytes(payload[12:],'big'))
   self.assertEqual(status()['control']['selected'],0)
   seq=int.from_bytes(payload[4:8],'big');emulator.sendto(ack(seq,2),('127.0.0.1',udp.getsockname()[1]))
   deadline=time.monotonic()+2
   while status()['control']['pending'] is not None and time.monotonic()<deadline:time.sleep(.02)
   self.assertEqual(status()['control']['selected'],2);self.assertIsNone(status()['control']['pending'])
  finally:emulator.close();stop.set();http.shutdown();http.server_close();udp.close();thread.join()
 def test_no_display_metrics(self):
  html=(r/'PC_VIEWER/web/index.html').read_text(encoding='utf-8');js=(r/'PC_VIEWER/web/app.js').read_text(encoding='utf-8')
  self.assertNotIn('fps',html.lower());self.assertNotIn('分辨率',html);self.assertNotIn('fps',js.lower());self.assertNotIn('landmark',js.lower())
if __name__=='__main__':unittest.main(verbosity=2)
