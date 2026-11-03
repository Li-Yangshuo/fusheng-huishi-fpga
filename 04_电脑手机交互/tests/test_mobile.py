from pathlib import Path
import sys,unittest,json,threading,urllib.request,urllib.error,http.cookiejar,time,base64,io
from http.cookiejar import CookieJar
from unittest.mock import patch
r=Path(__file__).resolve().parents[1];sys.path.insert(0,str(r/'PC_VIEWER'))
from mobile_access import MobileAccess
from server import make_server
class Tests(unittest.TestCase):
 def test_pair_and_lock(self):
  a=MobileAccess('192.168.5.5');self.assertFalse(a.authenticated('192.168.5.8',None))
  self.assertEqual(a.pair('10.0.0.1',a.pin),403)
  self.assertEqual(a.pair('192.168.5.8',a.pin),200)
  self.assertTrue(a.authenticated('192.168.5.8','M7Mobile='+a.session))
  self.assertFalse(a.authenticated('192.168.5.8','M7Mobile=bad'))
  wrong='000000' if a.pin!='000000' else '999999'
  for i in range(5):self.assertEqual(a.pair('192.168.5.9',wrong),403)
  self.assertEqual(a.pair('192.168.5.9',a.pin),429)
 def test_host_and_pin_scope(self):
  a=MobileAccess('192.168.5.5');self.assertFalse(a.host_allowed('untrusted.example:8765',8765))
  self.assertTrue(a.host_allowed('192.168.5.5:8765',8765))
  self.assertNotIn('pin',a.status(False,8765));self.assertIn('pin',a.status(True,8765))
 def test_mobile_http_pair_video_and_control(self):
  # Loopback requests emulate remote classification only; no exposure on physical LAN.
  http,udp,stop,rx,lock=make_server(0,0,demo=True)
  thread=threading.Thread(target=http.serve_forever,daemon=True);thread.start()
  url='http://127.0.0.1:'+str(http.server_port)
  opener=urllib.request.build_opener(urllib.request.ProxyHandler({}),urllib.request.HTTPCookieProcessor(CookieJar()))
  def get(path):return opener.open(url+path,timeout=10)
  try:
   local=json.load(get('/api/status'));pin=local['mobile']['pin']
   # Keep the peer/Host checks active, simulate remote connection for authorization.
   with patch.object(MobileAccess,'local',return_value=False),patch.object(MobileAccess,'peer_allowed',return_value=True):
    landing=get('/');self.assertEqual(landing.headers['Referrer-Policy'],'same-origin')
    self.assertIn('连接码',landing.read().decode())
    with self.assertRaises(urllib.error.HTTPError) as err:get('/api/status')
    self.assertEqual(err.exception.code,401)
    req=urllib.request.Request(url+'/pair',data=('pin='+pin).encode(),headers={'Origin':url})
    self.assertIn('M7 CREATIVE STUDIO',opener.open(req).read().decode())
    status=json.load(get('/api/status'));self.assertNotIn('pin',status['mobile'])
    deadline=time.monotonic()+4
    while time.monotonic()<deadline:
     response=get('/api/mobile-frame')
     if response.status==200:break
     time.sleep(.1)
    self.assertEqual(response.status,200);pair=json.load(response)
    from PIL import Image
    self.assertEqual(len(pair['images']),2)
    for data in pair['images']:
     im=Image.open(io.BytesIO(base64.b64decode(data)));self.assertEqual(im.size,(pair['width'],pair['height']))
    token=status['control_token']
    request=urllib.request.Request(url+'/api/style',data=b'{"style":1}',headers={'Content-Type':'application/json','X-Studio-Token':token,'Origin':'http://wrong.example'})
    with self.assertRaises(urllib.error.HTTPError) as err:opener.open(request)
    self.assertEqual(err.exception.code,403)
    # With valid paired cookie + origin + CSRF the request reaches the control handler.
    request=urllib.request.Request(url+'/api/style',data=b'{"style":1}',headers={'Content-Type':'application/json','X-Studio-Token':token,'Origin':url})
    with self.assertRaises(urllib.error.HTTPError) as err:opener.open(request)
    self.assertEqual(err.exception.code,400);self.assertIn('模拟模式',err.exception.read().decode())
  finally:stop.set();http.shutdown();http.server_close();udp.close();thread.join()
 def test_invalid_host_on_get(self):
  http,udp,stop,rx,lock=make_server(0,0);thread=threading.Thread(target=http.serve_forever,daemon=True);thread.start()
  try:
   req=urllib.request.Request('http://127.0.0.1:'+str(http.server_port)+'/api/status',headers={'Host':'untrusted.example'})
   with self.assertRaises(urllib.error.HTTPError) as err:urllib.request.build_opener(urllib.request.ProxyHandler({})).open(req)
   self.assertEqual(err.exception.code,403)
  finally:stop.set();http.shutdown();http.server_close();udp.close();thread.join()
if __name__=='__main__':unittest.main(verbosity=2)
