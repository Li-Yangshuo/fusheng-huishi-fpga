"""Create four direct BRAM initialization images from the unchanged RV32 image.

Little endian: lane0 holds bits7:0. Each lane has exactly 512 8-bit words.
The Verilog parameter MEM_FILE='cpu_boot.mem' reads cpu_boot.mem.lane0..3.
"""
from pathlib import Path
import argparse,hashlib,json

def split_boot(source,output=None):
    source=Path(source).resolve()
    words=[]
    for line in source.read_text(encoding='ascii').splitlines():
        line=line.split('//')[0].strip()
        if not line:continue
        for token in line.split():
            if token.startswith('@'):
                raise ValueError('Address directives are not accepted; use 512 sequential RV32 words')
            value=int(token,16)
            if not 0<=value<2**32:raise ValueError('RV32 word is outside 32 bits')
            words.append(value)
    if len(words) not in [512,1024,2048]:raise ValueError(f'Invalid RV32 depth {len(words)}')
    out=Path(output).resolve() if output else source.parent
    out.mkdir(parents=True,exist_ok=True)
    files=[]
    for lane in range(4):
        p=out/(source.name+f'.lane{lane}')
        p.write_text(''.join(f'{(word>>(8*lane))&255:02x}\n' for word in words),encoding='ascii')
        files.append(p)
    readback=[[int(x,16) for x in p.read_text(encoding='ascii').split()] for p in files]
    assert words==[sum(readback[lane][i]<<(8*lane) for lane in range(4)) for i in range(len(words))]
    sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
    return {'status':'PASS','source':str(source),'source_sha256':sha(source),'words':len(words),
            'first_word':f'{words[0]:08x}','lane_files':{p.name:sha(p) for p in files}}

if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source',type=Path)
    parser.add_argument('--output',type=Path)
    a=parser.parse_args()
    print(json.dumps(split_boot(a.source,a.output),indent=2))
