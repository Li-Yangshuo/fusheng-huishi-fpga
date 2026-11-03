from pathlib import Path
import subprocess,socket,json
c=json.loads((Path(__file__).parent/'network_config.json').read_text())
print('Expected PC:',c['pc_ip'],c['pc_mac'],'board:',c['board_ip'])
print('Read-only check. No network or firewall settings are changed.')
subprocess.run(['ipconfig','/all'])
s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM)
try:s.bind((c['pc_ip'],0));print('PASS: expected PC address is assigned')
except OSError as e:print('NOT READY: reconnect to the intended Wi-Fi and verify addresses:',e)
finally:s.close()
