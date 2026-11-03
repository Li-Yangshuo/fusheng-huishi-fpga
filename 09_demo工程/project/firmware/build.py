"""Build the actual RV32I machine-IRQ firmware used by this candidate."""
from pathlib import Path
import argparse,subprocess,hashlib,json,sys
R=Path(__file__).resolve().parents[1]; F=R/'firmware'; P=R/'structure/board_r6/project'
ap=argparse.ArgumentParser(); ap.add_argument('--toolchain',default='C:/Users/Lenovo/Documents/ChatGPT/New project/AB05R2_20261021/toolchain/xpack-riscv-none-elf-gcc-15.2.0-1/bin'); a=ap.parse_args()
T=Path(a.toolchain); O=F/'build'; O.mkdir(exist_ok=True)
def run(tool,args):
 q=subprocess.run([str(T/('riscv-none-elf-'+tool+'.exe')),*map(str,args)],cwd=F,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
 (O/(tool+'.log')).write_bytes(q.stdout)
 if q.returncode: raise RuntimeError(q.stdout.decode(errors='replace'))
 return q.stdout
run('gcc',['-march=rv32i_zicsr','-mabi=ilp32','-Os','-g','-ffreestanding','-fno-builtin','-ffunction-sections','-fdata-sections','-mno-relax','-msmall-data-limit=0','-nostdlib','-Wl,--gc-sections','-Wl,--build-id=none','-Wl,-Map='+str(O/'firmware.map'),'-T',F/'linker.ld',F/'startup.S',F/'main.c','-o',O/'firmware.elf'])
run('objcopy',['-O','binary',O/'firmware.elf',O/'firmware.bin'])
(O/'firmware.dis').write_bytes(run('objdump',['-d',O/'firmware.elf']))
raw_size=run('size',[O/'firmware.elf'])
try:size=raw_size.decode('utf-8')
except UnicodeDecodeError:size=raw_size.decode('gb18030',errors='replace')
print(size)
b=(O/'firmware.bin').read_bytes(); assert len(b)<=8192-768; b=b.ljust(8192,b'\0')
(P/'cpu_boot.mem').write_text(''.join(f'{int.from_bytes(b[i:i+4],"little"):08x}\n' for i in range(0,8192,4)),encoding='ascii')
sys.path.insert(0,str(R/'tools')); from split_boot_lanes import split_boot
lanes=split_boot(P/'cpu_boot.mem')
receipt={'status':'C_BUILD_PASS','binary_bytes':len((O/'firmware.bin').read_bytes()),'boot_bytes':8192,'reserved_stack_bytes':768,'isa':'rv32i_zicsr','size_output':size,'lane_check':lanes,'source_sha256':{p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in [F/'main.c',F/'startup.S',F/'linker.ld',F/'catalog.h']},'hardware_accessed':False}
(R/'evidence/FIRMWARE_BUILD.json').write_text(json.dumps(receipt,indent=2)); print(json.dumps(receipt,indent=2))
