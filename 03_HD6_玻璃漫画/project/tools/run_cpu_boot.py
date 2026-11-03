"""Actual inherited CPU firmware with the new model ID/asset CRC on MMIO."""
from pathlib import Path
import re,hashlib,json,subprocess,shutil,importlib.util,time,argparse
R=Path(__file__).resolve().parents[1];P=R/'structure/board_r6/project';M=Path('D:/modeltech_10.2c/win32')
ap=argparse.ArgumentParser();ap.add_argument('--output',type=Path,default=R/'evidence/cpu_boot_hd6');a=ap.parse_args();O=a.output.resolve();O.mkdir(parents=True,exist_ok=False)
V=R/'verification/cpu_boot';assert V.is_dir(),'Missing packaged CPU fixtures'
source=P/'rtl/soc/EfxSapphireSoc.v';soc=source.read_text()
modules={name:body for body,name in re.findall(r'(?ms)^(module\s+(\w+)\b.*?^endmodule\b)',soc)};used={'BmbUartCtrl','BmbSpiXdrMasterCtrl'}
while True:
 deps={name for selected in used for name in modules if re.search(r'\b'+re.escape(name)+r'\s+(?:#\s*\(.*?\)\s*)?\w+\s*\(',modules[selected],re.S)}
 if deps<=used:break
 used|=deps
(O/'peripherals_exact.v').write_text('`timescale 1ns/1ps\n'+'\n\n'.join(modules[n] for n in sorted(used)))
for n in ['cpu_boot.mem',*[f'cpu_boot.mem.lane{i}' for i in range(4)]]:shutil.copy2(P/n,O/n)
sources=[P/'rtl'/n for n in ['ab13_rv32i_manager.sv','ab10_cpu.v','ab10_control.v','soc/ram_inference.v']]+[O/'peripherals_exact.v',V/'tb_cpu_fault.sv']
def run(n,cmd):
 with (O/f'{n}.log').open('w') as f:q=subprocess.run([str(v) for v in cmd],cwd=O,stdout=f,stderr=subprocess.STDOUT)
 s=(O/f'{n}.log').read_text(errors='replace');assert q.returncode==0 and '** Error:' not in s and '** Fatal:' not in s,(n,s[-6000:]);return s
run('vlib',[M/'vlib.exe','work']);run('compile',[M/'vlog.exe','-sv','+define+OBSERVE',*sources]);run('opt',[M/'vopt.exe','work.tb_cpu_fault','-gCASE=1','+acc','-o','boot'])
s=run('simulate',[M/'vsim.exe','-c','work.boot','-do','onerror {quit -code 1 -f};onbreak {quit -code 1 -f};run -all;quit -code 0 -f']);assert 'CPU_FAULT PASS case=1' in s
spec=importlib.util.spec_from_file_location('iss',V/'check_retire_board.py');m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m);iss=m.verify(O/'cpu_boot.mem',O/'retire.csv')
res=dict(status='PASS',scope='Real inherited boot firmware, CPU and UART/SPI; branch model ID/CRC MMIO; RUN then injected fault -> ERR; independent instruction replay',model_mmio_id='54473031',asset_crc32=json.loads((R/'evidence/MODEL_BINDING.json').read_text())['packed_asset_crc32'],ISS=iss,uart=(O/'uart.txt').read_text(),source_sha256={str(p.relative_to(R)):hashlib.sha256(p.read_bytes()).hexdigest() for p in sources if p.is_relative_to(R)},retire_csv_sha256=hashlib.sha256((O/'retire.csv').read_bytes()).hexdigest(),hardware_accessed=False)
(O/'RESULTS.json').write_text(json.dumps(res,indent=2));print(json.dumps(res,indent=2))
