import sys,time,socket,threading,json,unittest,urllib.request,zlib
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'PC_VIEWER'))
from protocol import Receiver,HEADER,packets
from server import make_server

def rows(fid,stream=0,session=7,pixel=b'\x00\xf8'):
 data=pixel*4
 for y in range(2):
  payload=data[y*4:y*4+4]
  yield HEADER.pack(b'FPGV',2,1,stream,0,session,fid,2,2,y,2,4,0,8,zlib.crc32(payload),0)+payload

class RecoveryTests(unittest.TestCase):
 def setUp(self):
  self.now=10.;self.rx=Receiver(clock=lambda:self.now)
 def feed(self,fid,stream=0,session=7):
  for p in rows(fid,stream,session):self.rx.feed(p)
 def test_same_session_reset_recovers(self):
  self.feed(50000);old=self.rx.revision;self.now+=2.1
  for fid in range(4):self.feed(fid);self.now+=.1
  self.assertEqual(self.rx.latest[0]['frame_id'],3)
  self.assertEqual(self.rx.stats['frame_id_resyncs'],1)
  self.assertGreater(self.rx.revision,old)
  self.feed(3,1);self.assertEqual(self.rx.latest[1]['epoch'],self.rx.latest[0]['epoch'])
  self.feed(4);self.assertEqual(self.rx.latest[0]['frame_id'],4)
 def test_duplicates_and_single_stale_do_not_reset(self):
  self.feed(50000);self.now+=3
  for _ in range(20):self.feed(1);self.now+=.02
  self.assertEqual(self.rx.last_ids[0],50000);self.assertEqual(self.rx.stats['frame_id_resyncs'],0)
 def test_active_stream_and_reordering_do_not_reset(self):
  self.feed(50000)
  for fid in range(20):self.now+=.05;self.feed(fid)
  self.assertEqual(self.rx.last_ids[0],50000)
  self.now+=2
  for fid in (9,8,7,6,5):self.feed(fid);self.now+=.1
  self.assertEqual(self.rx.stats['frame_id_resyncs'],0)
 def test_invalid_crc_and_nonzero_rows_do_not_reset(self):
  self.feed(50000);self.now+=3
  for fid in range(10):
   ps=list(rows(fid));corrupt=bytearray(ps[0]);corrupt[-1]^=1
   self.rx.feed(corrupt);self.rx.feed(ps[1]);self.now+=.05
  self.assertEqual(self.rx.stats['crc_failures'],10)
  self.assertEqual(self.rx.stats['frame_id_resyncs'],0)
 def test_candidate_expiry_and_live_other_stream(self):
  self.feed(50000);self.now+=3
  for fid in range(6):self.feed(fid);self.now+=1.1
  self.assertEqual(self.rx.stats['frame_id_resyncs'],0)
  for fid in range(6,15):self.feed(50000+fid,1);self.feed(fid);self.now+=.1
  self.assertEqual(self.rx.stats['frame_id_resyncs'],0)
 def test_wrap_session_and_v1(self):
  self.feed(0xfffffffe);self.feed(0xffffffff);self.feed(0)
  self.assertEqual(self.rx.last_ids[0],0);self.assertEqual(self.rx.stats['frame_id_resyncs'],0)
  self.now+=3.1;self.feed(1,session=8);self.assertEqual(self.rx.owner[1],8)
  for p in packets(b'\0'*8,2,2,2,session=8):self.rx.feed(p)
  self.assertEqual(self.rx.last_ids[0],2)
 def test_real_udp_atomic_pair_reset_and_stale(self):
  http,udp,stop,rx,lock=make_server(0,0,source_ip='127.0.0.1')
  thread=threading.Thread(target=http.serve_forever,daemon=True);thread.start()
  sock=socket.socket(socket.AF_INET,socket.SOCK_DGRAM)
  opener=urllib.request.build_opener(urllib.request.ProxyHandler({}))
  url='http://127.0.0.1:'+str(http.server_port)
  def send(fid,stream):
   for p in rows(fid,stream,pixel=b'\x00\xf8' if stream==0 else b'\xe0\x07'):sock.sendto(p,('127.0.0.1',udp.getsockname()[1]))
   time.sleep(.015)
  def get(path):return opener.open(url+path,timeout=3)
  try:
   send(50000,0);send(50001,0);send(50000,1)
   with get('/api/frame-pair') as response:
    self.assertEqual(response.status,200);self.assertEqual(response.headers['X-Frame-ID'],'50000')
    key=response.headers['X-Pair-Key'];data=response.read()
    self.assertEqual(data,b'\x00\xf8'*4+b'\xe0\x07'*4)
   self.assertEqual(get('/api/frame-pair?after='+key).status,204)
   with lock:
    for f in rx.latest.values():f['received_at']-=3
   for fid in range(4):send(fid,0)
   self.assertEqual(get('/api/frame-pair').status,204) # old pair cleared
   send(3,1)
   with get('/api/frame-pair?after='+key) as response:
    self.assertEqual(response.status,200);self.assertEqual(response.headers['X-Frame-ID'],'3')
    self.assertNotEqual(response.headers['X-Pair-Key'],key)
   with lock:
    self.assertEqual(rx.stats['frame_id_resyncs'],1)
    for f in rx.latest.values():f['received_at']-=3
   self.assertEqual(get('/api/frame-pair').status,204)
   self.assertEqual(get('/api/frame/0').status,204)
  finally:
   sock.close();stop.set();http.shutdown();http.server_close();udp.close();thread.join()

if __name__=='__main__':unittest.main(verbosity=2)
