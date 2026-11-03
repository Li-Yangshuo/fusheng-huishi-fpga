"""Read Efinity RAM-info protobuf fields and verify mapped CPU boot contents.

This checks the mapped BRAM data, not behavioral $readmemh. No vendor protobuf
Python dependency is required. EFX_RAM10 uses INIT_0..27 concatenated low first;
each INIT value is 256 bits, with address zero in its least significant bits.
"""
from pathlib import Path
import argparse,hashlib,json,re

def varint(data,offset):
    value=shift=0
    while True:
        byte=data[offset];offset+=1;value|=(byte&127)<<shift;shift+=7
        if byte<128:return value,offset
        if shift>70:raise ValueError('Invalid protobuf varint')

def fields(data):
    result=[];offset=0
    while offset<len(data):
        key,offset=varint(data,offset);number,kind=key>>3,key&7
        if kind==0:value,offset=varint(data,offset)
        elif kind==2:
            size,offset=varint(data,offset);value=data[offset:offset+size];offset+=size
        elif kind in [1,5]:
            size=8 if kind==1 else 4;value=data[offset:offset+size];offset+=size
        else:raise ValueError(f'Unexpected protobuf wire type {kind}')
        result.append((number,kind,value))
    return result

def mapped_lanes(path):
    result={}
    for number,kind,data in fields(Path(path).read_bytes()):
        if number!=1 or kind!=2:continue
        info=fields(data)
        name=next((v.decode('ascii') for f,k,v in info if f==2 and k==2),'')
        match=re.search(r'(?:^|/)boot_lane\[([0-3])\]\.mem$',name)
        if not match:continue
        lane=int(match[1]);depth=next(v for f,k,v in info if f==4)
        width=next(v for f,k,v in info if f==5)
        slices=[fields(v) for f,k,v in info if f==7 and k==2]
        assert depth==512 and width==8 and len(slices)==1,(name,depth,width,len(slices))
        q=slices[0]
        assert next(v for f,k,v in q if f==8)==8,(name,'physical width changed')
        chunks=[v.decode('ascii') for f,k,v in q if f==9 and k==2]
        assert len(chunks)==40 and all(len(h)==64 for h in chunks),(name,'INIT geometry changed')
        raw=b''.join(int(h,16).to_bytes(32,'little') for h in chunks)
        result[lane]={'name':name,'data':raw[:512], 'all_init_zero':not any(raw)}
    assert set(result)=={0,1,2,3},f'Missing CPU boot memories: {list(result)}'
    return result

def verify(raminfo,boot,expect_zero=False):
    raminfo=Path(raminfo);boot=Path(boot)
    expected=[int(x,16) for x in boot.read_text(encoding='ascii').split()]
    assert len(expected)==512
    lanes=mapped_lanes(raminfo)
    words=[sum(lanes[lane]['data'][i]<<(8*lane) for lane in range(4)) for i in range(512)]
    mismatches=sum(a!=b for a,b in zip(words,expected))
    if expect_zero:
        assert all(v['all_init_zero'] for v in lanes.values()) and any(expected)
    else:
        assert mismatches==0,f'{mismatches} mapped CPU words differ from boot file'
    sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
    return {'status':'ZERO_INIT_NEGATIVE_REPRODUCED' if expect_zero else 'PASS',
            'raminfo':str(raminfo.resolve()),'raminfo_sha256':sha(raminfo),'boot_sha256':sha(boot),
            'words_checked':512,'bytes_checked':2048,'word_mismatches':mismatches,
            'expected_first_word':f'{expected[0]:08x}','mapped_first_word':f'{words[0]:08x}',
            'lanes':{str(lane):{'name':v['name'],'all_init_zero':v['all_init_zero'],
                     'logical_bytes_sha256':hashlib.sha256(v['data']).hexdigest()} for lane,v in lanes.items()}}

if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--raminfo',required=True,type=Path);p.add_argument('--boot',required=True,type=Path)
    p.add_argument('--expect-zero',action='store_true');p.add_argument('--receipt',type=Path)
    a=p.parse_args();r=verify(a.raminfo,a.boot,a.expect_zero)
    text=json.dumps(r,indent=2)
    if a.receipt:a.receipt.write_text(text,encoding='utf-8')
    print(text)
