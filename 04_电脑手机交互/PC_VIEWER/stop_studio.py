import json,urllib.request
opener=urllib.request.build_opener(urllib.request.ProxyHandler({}))
url='http://127.0.0.1:8765'
try:
 instance=json.load(opener.open(url+'/api/instance',timeout=2))
 if instance.get('app')!='M7_STUDIO':raise RuntimeError('Not an M7 server; nothing stopped')
 state=json.load(opener.open(url+'/api/status',timeout=2))
 request=urllib.request.Request(url+'/api/shutdown',data=b'{}',headers={'X-Studio-Token':state['control_token']})
 opener.open(request,timeout=3).close();print('M7 stopped.')
except Exception as e:print('Unable to stop M7:',e)
