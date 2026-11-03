"""Test a second HTTP listener on this PC's actual LAN address, without board access."""
from pathlib import Path
import sys,json,threading,time,urllib.request,urllib.error,http.cookiejar
r=Path(__file__).resolve().parents[1];sys.path.insert(0,str(r/'PC_VIEWER'))
from server import make_server
ip=sys.argv[1]
server,udp,stop,rx,lock=make_server(0,0,demo=True,lan_ip=ip)
thread=threading.Thread(target=server.serve_forever,daemon=True);thread.start()
pc='http://127.0.0.1:'+str(server.server_port);phone='http://'+ip+':'+str(server.server_port)
opener=urllib.request.build_opener(urllib.request.ProxyHandler({}),urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar()))
try:
 deadline=time.monotonic()+5
 while time.monotonic()<deadline:
  state=json.load(opener.open(pc+'/api/status'))
  if state['mobile']['ready']:break
  time.sleep(.1)
 assert state['mobile']['ready']
 assert '连接码' in opener.open(phone+'/').read().decode()
 try:opener.open(phone+'/api/status');raise AssertionError('Unauthenticated status exposed')
 except urllib.error.HTTPError as e:assert e.code==401
 opener.open(urllib.request.Request(phone+'/pair',data=('pin='+state['mobile']['pin']).encode(),headers={'Origin':phone})).close()
 paired=json.load(opener.open(phone+'/api/status'));assert paired['mobile']['client']=='phone';assert 'pin' not in paired['mobile']
 deadline=time.monotonic()+4
 while time.monotonic()<deadline:
  response=opener.open(phone+'/api/mobile-frame')
  if response.status==200:break
  time.sleep(.1)
 assert response.status==200
 pair=json.load(response);assert len(pair['images'])==2
 result={'status':'PASS','real_lan_socket_bind':True,'pair_cookie':True,'compressed_pair':True,'tested_pc_lan_ip':ip,'physical_phone_verified':False,'board_video_verified':False}
 (r/'tests/LAN_LISTENER_RESULT.json').write_text(json.dumps(result,indent=2));print(json.dumps(result))
finally:stop.set();server.shutdown();server.server_close();udp.close();thread.join()
