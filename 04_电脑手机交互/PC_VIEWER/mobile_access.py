"""Per-run LAN pairing. No router settings or external services."""
import ipaddress,secrets,time,threading
from http.cookies import SimpleCookie

class MobileAccess:
    def __init__(self,lan_ip):
        ip=ipaddress.ip_address(lan_ip)
        if ip.version!=4 or not ip.is_private or ip.is_loopback or ip.is_unspecified:
            raise ValueError('手机入口须为电脑的局域网 IPv4 地址')
        self.lan_ip=str(ip);self.network=ipaddress.ip_network(self.lan_ip+'/24',strict=False)
        self.pin=f'{secrets.randbelow(1000000):06d}';self.session=secrets.token_urlsafe(32)
        self.failures={};self.lock=threading.Lock();self.ready=False;self.error='等待电脑连接板卡路由器'
    @staticmethod
    def local(address):return ipaddress.ip_address(address).is_loopback
    def peer_allowed(self,address):
        return self.local(address) or ipaddress.ip_address(address) in self.network
    def host_allowed(self,host,port):
        return host in (f'127.0.0.1:{port}',f'localhost:{port}',f'{self.lan_ip}:{port}')
    def authenticated(self,address,cookie):
        if self.local(address):return True
        if not self.peer_allowed(address):return False
        try:
            c=SimpleCookie();c.load(cookie or '');item=c.get('M7Mobile')
            return bool(item and secrets.compare_digest(item.value,self.session))
        except Exception:return False
    def pair(self,address,pin):
        if not self.peer_allowed(address):return 403
        with self.lock:
            now=time.monotonic()
            self.failures={k:[t for t in v if now-t<60] for k,v in self.failures.items() if any(now-t<60 for t in v)}
            failed=self.failures.setdefault(address,[])
            if len(failed)>=5:return 429
            if len(pin)==6 and pin.isascii() and secrets.compare_digest(pin,self.pin):
                self.failures.pop(address,None);return 200
            failed.append(now);return 403
    def status(self,local,port):
        result={'client':'pc' if local else 'phone','ready':self.ready}
        if local:result.update({'url':f'http://{self.lan_ip}:{port}','pin':self.pin,'note':self.error})
        return result

PAIR_PAGE='''<!doctype html><html lang="zh-CN"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>M7 手机连接</title><style>body{font:16px/1.7 "Microsoft YaHei",sans-serif;background:#eff6ff;color:#355b88;margin:0;padding:48px 24px}main{max-width:380px;margin:auto;background:white;border:1px solid #d8e7fa;border-radius:24px;padding:28px}h1{font-size:24px;color:#2465ba}input,button{box-sizing:border-box;width:100%;padding:13px;border:1px solid #bed5f1;border-radius:12px;font:inherit}button{background:#2879e6;color:white;margin-top:18px}p{font-size:14px;color:#7792b3}input{font-size:28px;letter-spacing:8px;text-align:center}</style><main><h1>M7 · 手机连接</h1><p>在电脑控制台展开“手机连接”，输入本次启动的六位连接码。</p><form action="/pair" method="post"><input name="pin" aria-label="连接码" inputmode="numeric" pattern="[0-9]{6}" minlength="6" maxlength="6" required autocomplete="off"><button>连接控制台</button></form><p>手机、电脑与板卡须连接同一路由器。电脑服务需保持运行。</p></main></html>'''
