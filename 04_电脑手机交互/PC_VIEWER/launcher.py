"""Launch one M7 instance. Replace only a positively identified old M7 server."""
from pathlib import Path
import json,subprocess,sys,time,urllib.request,webbrowser,socket
ROOT=Path(__file__).resolve().parent
URL='http://127.0.0.1:8765'
opener=urllib.request.build_opener(urllib.request.ProxyHandler({}))
def get(path):
    with opener.open(URL+path,timeout=2) as r:return r.read()
def existing():
    try:
        status=json.loads(get('/api/status'));html=get('/').decode('utf-8')
        if status.get('protocol')!='FPGV/1+2' or 'M7 CREATIVE STUDIO' not in html:return None
        try:instance=json.loads(get('/api/instance'))
        except Exception:instance={}
        return status,instance
    except Exception:return None
def replace_old(status,instance):
    if instance.get('release')=='R6.1' and instance.get('root')==str(ROOT):return False
    if instance.get('app')=='M7_STUDIO':
        req=urllib.request.Request(URL+'/api/shutdown',data=b'{}',headers={'Content-Type':'application/json','X-Studio-Token':status['control_token']})
        opener.open(req,timeout=3).close();return True
    # Older releases had no shutdown endpoint. Confirm listener PID, UDP owner and script.
    ps="""$owner=(Get-NetTCPConnection -LocalPort 8765 -State Listen -ErrorAction Stop | Where-Object LocalAddress -eq '127.0.0.1' | Select-Object -First 1).OwningProcess
$process=Get-CimInstance Win32_Process -Filter "ProcessId=$owner"
$udp=Get-NetUDPEndpoint -LocalPort 18500 -ErrorAction Stop | Where-Object OwningProcess -eq $owner
if (-not $udp -or $process.Name -notmatch '^python(w)?\\.exe$' -or $process.CommandLine -notmatch '(?i)(^|[\\s/\\\\])server\\.py([\\s\"]|$)') {throw 'Unrecognized process; not stopped'}
Stop-Process -Id $owner -ErrorAction Stop
Write-Output 'Old M7 stopped'
"""
    p=subprocess.run(['powershell','-NoProfile','-Command',ps],capture_output=True,text=True)
    if p.returncode:raise RuntimeError('无法安全识别旧服务，请关闭旧上位机窗口后重试。\n'+p.stderr)
    return True
def main():
    print('M7 R6.1 - blue/white PC and phone console',flush=True)
    current=existing()
    if current:
        status,instance=current
        if not replace_old(status,instance):
            print('R6.1 is already running. Opening its page.',flush=True);webbrowser.open(URL);return
        print('Old M7 instance stopped; starting R6.1.',flush=True)
        for _ in range(30):
            try:
                with socket.create_connection(('127.0.0.1',8765),timeout=.2):pass
            except OSError:break
            time.sleep(.1)
    config=json.loads((ROOT/'network_config.json').read_text(encoding='utf-8'))
    (ROOT/'logs').mkdir(exist_ok=True)
    print('PC: '+URL,flush=True)
    print('Phone: http://'+config['pc_ip']+':8765 (PC and phone must join the board router)',flush=True)
    print('Use STOP_M7.cmd to stop the service. Logs: PC_VIEWER/logs/studio.log',flush=True)
    with (ROOT/'logs/studio.log').open('a',encoding='utf-8') as log:
        proc=subprocess.Popen([sys.executable,'-X','utf8',str(ROOT/'server.py'),'--lan-ip',config['pc_ip']],cwd=ROOT,stdout=log,stderr=log)
        try:
            for _ in range(60):
                if proc.poll() is not None:raise RuntimeError('启动失败。请查看 PC_VIEWER/logs/studio.log；若端口由其他程序占用，请先关闭该程序。')
                current=existing()
                if current and current[1].get('release')=='R6.1' and current[1].get('root')==str(ROOT):
                    webbrowser.open(URL);break
                time.sleep(.25)
            else:raise RuntimeError('网页未在预期时间内就绪，请查看启动日志。')
            proc.wait()
        except KeyboardInterrupt:
            try:
                st=json.loads(get('/api/status'))
                opener.open(urllib.request.Request(URL+'/api/shutdown',data=b'{}',headers={'X-Studio-Token':st['control_token']}),timeout=2).close()
                proc.wait(timeout=5)
            except Exception:
                if proc.poll() is None:proc.terminate()
        finally:
            if proc.poll() is None:proc.terminate()
if __name__=='__main__':
    try:main()
    except Exception as e:print(str(e),flush=True);raise SystemExit(1)
