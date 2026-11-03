from pathlib import Path
import argparse,ipaddress,re,json
r=Path(__file__).resolve().parents[1];a=argparse.ArgumentParser()
a.add_argument('--pc-ip',required=True);a.add_argument('--pc-mac',required=True);a.add_argument('--board-ip',default='192.168.5.60');x=a.parse_args()
pc=ipaddress.IPv4Address(x.pc_ip);board=ipaddress.IPv4Address(x.board_ip);net=ipaddress.IPv4Network(str(board)+'/24',strict=False)
assert pc in net,'This experiment requires PC and board in the same /24 subnet'
mac=x.pc_mac.replace(':','').replace('-','');assert re.fullmatch('[0-9a-fA-F]{12}',mac) and not int(mac[:2],16)&1
updates={'m7_udp_video.sv':{'DST_MAC':(48,mac.lower()),'DST_IP':(32,f'{int(pc):08x}'),'SRC_IP':(32,f'{int(board):08x}')},'m7_control_rx.sv':{'PC_MAC':(48,mac.lower()),'PC_IP':(32,f'{int(pc):08x}'),'BOARD_IP':(32,f'{int(board):08x}')}}
for filename,fields in updates.items():
 p=r/'rtl/network'/filename;s=p.read_text()
 for name,(width,value) in fields.items():
  s,n=re.subn(name+r"="+str(width)+r"'h[0-9a-fA-F]+",name+'='+str(width)+"'h"+value,s);assert n==1
 p.write_text(s)
cfg={'board_ip':str(board),'pc_ip':str(pc),'pc_mac':':'.join(mac[i:i+2].upper() for i in range(0,12,2)),'broadcast':str(net.broadcast_address)}
(r.parent/'PC_VIEWER/network_config.json').write_text(json.dumps(cfg,indent=2))
print('TX + RX RTL and PC configuration updated. Run a FULL build; current BIT is unchanged.')
