import unittest,struct,random,zlib,threading,urllib.request,json,socket,time
from protocol import Receiver,packets,HEADER
from server import make_server
class Clock:
 def __init__(self):self.t=0.0
 def __call__(self):return self.t
class ProtocolTests(unittest.TestCase):
 def setUp(self):self.c=Clock();self.r=Receiver(clock=self.c);self.data=bytes(range(256))*24
 def send(self,fid=1,**kw):
  ps=list(packets(self.data,64,48,fid,**kw))
  for p in ps:self.r.feed(p)
  return ps
 def test_reordered_and_duplicate(self):
  ps=list(packets(self.data,64,48,1));ps=list(reversed(ps));self.r.feed(ps[0]);self.r.feed(ps[0])
  for p in ps[1:]:self.r.feed(p)
  self.assertEqual(self.r.latest[0]['data'],self.data);self.assertEqual(self.r.stats['duplicate_packets'],1)
 def test_crc_and_malformed(self):
  ps=list(packets(self.data,64,48,1));ps[-1]=ps[-1][:-1]+bytes([ps[-1][-1]^1])
  for p in ps:self.r.feed(p)
  self.assertEqual(self.r.stats['crc_failures'],1);self.assertFalse(self.r.latest)
  self.r.feed(b'bad');self.r.feed(ps[0]+b'extra');self.assertEqual(self.r.stats['invalid_packets'],2)
 def test_timeout_and_memory_bound(self):
  for i in range(20):self.r.feed(next(packets(self.data,64,48,i)))
  self.assertLessEqual(len(self.r.pending),4);self.c.t=2;self.r.expire();self.assertEqual(len(self.r.pending),0)
  self.assertEqual(self.r.stats['incomplete_frames'],20)
 def test_conflict(self):
  ps=list(packets(self.data,64,48,1));self.r.feed(ps[0]);self.r.feed(ps[0][:-1]+bytes([ps[0][-1]^1]))
  for p in ps[1:]:self.r.feed(p)
  self.assertFalse(self.r.latest);self.assertEqual(self.r.stats['conflicting_packets'],1)
 def test_fps_and_stop(self):
  for i in range(12):self.c.t=i/15;self.send(i)
  self.assertAlmostEqual(self.r.snapshot()['streams']['0']['fps'],15,places=6)
  self.c.t+=1.6;self.assertEqual(self.r.snapshot()['streams']['0']['fps'],0)
 def test_frame_id_wrap_and_gap(self):
  for i in [0xfffffffe,0xffffffff,0,2]:self.send(i)
  self.assertEqual(self.r.last_ids[0],2);self.assertEqual(self.r.stats['sequence_gaps_0'],1)
  self.send(1);self.assertEqual(self.r.last_ids[0],2)
 def test_source_session_isolation(self):
  self.send(session=3);self.send(fid=2,session=4);self.assertEqual(self.r.owner[1],3)
  self.c.t=3.1;self.send(fid=1,session=4);self.assertEqual(self.r.owner[1],4)
 def test_source_filter(self):
  self.r=Receiver(source_ip='192.168.1.20',clock=self.c);self.send();self.assertFalse(self.r.latest)
 def test_streams_rgb888_demo(self):
  for p in packets(bytes([255,0,0,0,255,0]),2,1,3,fmt=2,stream=1,demo=True):self.r.feed(p)
  f=self.r.latest[1];self.assertEqual(f['format'],2);self.assertTrue(f['demo']);self.assertEqual(f['width'],2)
 def test_invalid_header_lengths(self):
  p=bytearray(next(packets(self.data,64,48,1)));p[16:18]=b'\xff\xff';self.r.feed(p);self.assertFalse(self.r.pending)
class Integration(unittest.TestCase):
 def test_udp_http_roundtrip_and_idle(self):
  http,udp,stop,rec,lock=make_server(0,0);t=threading.Thread(target=http.serve_forever,daemon=True);t.start()
  base='http://127.0.0.1:'+str(http.server_port);tx=socket.socket(socket.AF_INET,socket.SOCK_DGRAM)
  try:
   self.assertIn(b'M7 CREATIVE STUDIO',urllib.request.urlopen(base+'/').read())
   with urllib.request.urlopen(base+'/api/frame/0') as f:self.assertEqual(f.status,204)
   raw=bytes([0,248,224,7,31,0,255,255])
   for p in packets(raw,2,2,8,session=78):tx.sendto(p,('127.0.0.1',udp.getsockname()[1]))
   for _ in range(50):
    d=json.load(urllib.request.urlopen(base+'/api/status'))
    if d['streams']['0']['frames']:break
    time.sleep(.01)
   self.assertEqual(d['streams']['0']['frames'],1);self.assertFalse(d['streams']['0']['demo'])
   with urllib.request.urlopen(base+'/api/frame/0') as f:
    self.assertEqual(f.read(),raw);self.assertEqual(f.headers['X-Frame-ID'],'8');rev=f.headers['X-Frame-Revision']
   with urllib.request.urlopen(base+'/api/frame/0?after='+rev) as f:self.assertEqual(f.status,204)
   self.assertEqual(http.server_address[0],'127.0.0.1')
  finally:stop.set();udp.close();tx.close();http.shutdown();http.server_close()
if __name__=='__main__':unittest.main(verbosity=2)
