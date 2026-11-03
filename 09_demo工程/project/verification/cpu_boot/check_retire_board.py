"""Independent scalar RV32I interpreter replaying bus read responses only.

Every retired PC/instruction/rd/result is checked. Program/data memory is owned
by this interpreter; data stores and branch decisions are recomputed. No RTL
register or ALU intermediate is read by this checker.
"""
from pathlib import Path
from collections import deque,Counter
import json,struct
MASK=(1<<32)-1
def sx(x,n):return (x&((1<<(n-1))-1))-(x&(1<<(n-1)))
def verify(memfile,trace):
    mem=bytearray().join(struct.pack('<I',int(x,16)) for x in Path(memfile).read_text().split())
    reg=[0]*32;pc=0xf9000000;pending=deque();counts=Counter();insns=0;trapped=False
    def load(ad,size):
        assert ad>=0xf9000000 and ad+size<=0xf9000800,hex(ad)
        return int.from_bytes(mem[ad-0xf9000000:ad-0xf9000000+size],'little')
    def bus(ad,write,value=0):
        aa,ww,v,err=pending.popleft();assert (aa,ww)==(ad,write),(hex(pc),aa,ww,ad,write)
        assert not err
        if write:assert value==v,(hex(ad),value,v)
        return v
    for line in Path(trace).read_text().splitlines():
        row=line.split(',')
        if row[0]=='B':pending.append((int(row[1],16),int(row[2]),int(row[3],16),int(row[4])));continue
        if row[0]=='T':
            assert pending and pending[0][-1]==1
            trapped=True;break
        assert row[0]=='I',row
        actual_pc,actual_ir,actual_rd,actual_v=int(row[1],16),int(row[2],16),int(row[3]),int(row[4],16)
        ir=load(pc,4);assert (pc,ir)==(actual_pc,actual_ir),(hex(pc),hex(ir),row)
        op=ir&127;rd=(ir>>7)&31;f3=(ir>>12)&7;r1=(ir>>15)&31;r2=(ir>>20)&31;f7=ir>>25
        a,b=reg[r1],reg[r2];ip=sx(ir>>20,12);v=0;dest=rd;npc=(pc+4)&MASK;name=f'{op:02x}/{f3}/{f7:02x}'
        if op==0x37:v=ir&0xfffff000
        elif op==0x17:v=pc+(ir&0xfffff000)
        elif op==0x6f:
            v=pc+4;j=((ir>>31)<<20)|(((ir>>12)&255)<<12)|(((ir>>20)&1)<<11)|(((ir>>21)&1023)<<1);npc=(pc+sx(j,21))&MASK
        elif op==0x67:v=pc+4;npc=(a+ip)&0xfffffffe
        elif op==0x63:
            dest=0;bi=((ir>>31)<<12)|(((ir>>7)&1)<<11)|(((ir>>25)&63)<<5)|(((ir>>8)&15)<<1)
            cond={0:a==b,1:a!=b,4:sx(a,32)<sx(b,32),5:sx(a,32)>=sx(b,32),6:a<b,7:a>=b}[f3]
            if cond:npc=(pc+sx(bi,13))&MASK
        elif op in (0x13,0x33):
            c=(ip&MASK) if op==0x13 else b
            if f3==0:v=a-c if op==0x33 and f7==0x20 else a+c
            elif f3==1:v=a<<(c&31)
            elif f3==2:v=int(sx(a,32)<sx(c,32))
            elif f3==3:v=int(a<c)
            elif f3==4:v=a^c
            elif f3==5:v=(sx(a,32) if ir&(1<<30) else a)>>(c&31)
            elif f3==6:v=a|c
            elif f3==7:v=a&c
        elif op==0x03:
            ad=(a+ip)&MASK;size={0:1,1:2,2:4,4:1,5:2}[f3]
            v=load(ad,size) if ad>>24!=0xf8 else bus(ad,0)
            if f3 in (0,1):v=sx(v,size*8)
        elif op==0x23:
            dest=0;imm=sx(((ir>>25)<<5)|((ir>>7)&31),12);ad=(a+imm)&MASK;size={0:1,1:2,2:4}[f3]
            if ad>>24==0xf8:bus(ad,1,b)
            else:
                assert 0xf9000000<=ad and ad+size<=0xf9000800
                mem[ad-0xf9000000:ad-0xf9000000+size]=(b&((1<<(size*8))-1)).to_bytes(size,'little')
        elif op==0x0f:dest=0
        else:raise AssertionError(f'unsupported ISA opcode {ir:08x}')
        v&=MASK
        if dest==0:v=0
        assert (dest,v)==(actual_rd,actual_v),(hex(pc),hex(ir),dest,hex(v),actual_rd,hex(actual_v))
        if dest:reg[dest]=v
        reg[0]=0;pc=npc;insns+=1;counts[name]+=1
    assert trapped or not pending,list(pending)
    return dict(status='PASS',retired_instructions=insns,opcode_variants=dict(counts),expected_bus_error_trap=trapped,final_pc=f'{pc:08x}')
if __name__=='__main__':
    import sys
    print(json.dumps(verify(sys.argv[1],sys.argv[2]),indent=2))
