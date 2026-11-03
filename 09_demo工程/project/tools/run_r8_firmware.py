from pathlib import Path
import subprocess,json,re,shutil,hashlib,time
R=Path(__file__).resolve().parents[1];P=R/'structure/board_r6/project';M=Path('D:/modeltech_10.2c/win32');O=R/'evidence/r8_firmware';O.mkdir(exist_ok=True)
for n in ['cpu_boot.mem',*[f'cpu_boot.mem.lane{i}' for i in range(4)],'hd_weights.mem','hd_bias.mem']:shutil.copy2(P/n,O/n)
camera=json.loads((R/'firmware/CATALOG_REFERENCE.json').read_text())
table=re.search(r'camera_table\[\] = \{(.*?)\};',(R/'firmware/catalog.h').read_text(),re.S).group(1)
(O/'camera_expected.mem').write_text(''.join(v+'\n' for v in re.findall(r'0x([0-9a-f]+)u',table)))
D=P/'rtl/cam_i2c_ctrl'; S=[P/'rtl/ab13_rv32i_manager.sv',R/'rtl/r8_control.sv',R/'rtl/r8_camera_mmio.sv',R/'rtl/hd720_fused_core.sv',D/'i2c/i2c_16addr_8data.v',D/'i2c_master/i2c_master_top.v',D/'i2c_master/i2c_master_byte_ctrl.v',D/'i2c_master/i2c_master_bit_ctrl.v',R/'verification/tb_r8_firmware.sv']
def run(n,cmd):
 with (O/(n+'.log')).open('w') as f:q=subprocess.run(list(map(str,cmd)),cwd=O,stdout=f,stderr=subprocess.STDOUT)
 s=(O/(n+'.log')).read_text(errors='replace');assert q.returncode==0 and '** Error:' not in s and '** Fatal:' not in s,(n,s[-7000:]);return s
run('vlib',[M/'vlib.exe','work']);run('compile',[M/'vlog.exe','-sv','+incdir+'+str(D/'i2c_master'),*S]);out=[]
for fault,divider in [(0,3),(1,3),(2,3),(0,659)]:
 name='case'+str(fault)+'_div'+str(divider);run('opt_'+name,[M/'vopt.exe','work.tb_r8_firmware',f'-gFAULT={fault}',f'-gCAM_DIV={divider}','+acc','-o',name]);s=run(name,[M/'vsim.exe','-c','work.'+name,'-do','onerror {quit -code 1 -f};onbreak {quit -code 1 -f};run -all;quit -code 0 -f']);assert 'R8_FIRMWARE PASS' in s;out += [v for v in s.splitlines() if 'R8_FIRMWARE PASS' in v];print(out[-1],flush=True)
result={'status':'PASS','scope':'Actual compiled C firmware on delivered RV32I/CSR CPU; physical-I2C behavioral ACK/NACK/clock-stall slave; active CNN parameter memories; IRQ/mret and C-controlled UI','camera_simulation_dividers':[3,659],'release_divider':659,'active_memories_poisoned_before_C_boot':True,'hardware_accessed':False,'results':out,'source_sha256':{str(p.relative_to(R)):hashlib.sha256(p.read_bytes()).hexdigest() for p in S},'boot_sha256':hashlib.sha256((P/'cpu_boot.mem').read_bytes()).hexdigest()}
(O/'RESULTS.json').write_text(json.dumps(result,indent=2));print(O)
