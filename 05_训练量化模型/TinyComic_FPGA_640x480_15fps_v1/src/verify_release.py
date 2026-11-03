from pathlib import Path
import argparse,json,hashlib,re
import numpy as np
from PIL import Image
from integer_reference import preprocess,infer_rgb,infer_low
def header(text,name):
    m=re.search(r'\b'+name+r'\[(\d+)\]\s*=\s*\{([^}]+)\}',text);assert m,name
    x=np.array([int(v) for v in m[2].split(',')]);assert len(x)==int(m[1]);return x
def main():
    ap=argparse.ArgumentParser();ap.add_argument('--root',type=Path,default=Path(__file__).resolve().parents[1]);r=ap.parse_args().root
    m=json.loads((r/'MANIFEST.json').read_text(encoding='utf-8'))
    for row in m['files']:
        p=r/row['path'];assert p.stat().st_size==row['bytes'];assert hashlib.sha256(p.read_bytes()).hexdigest()==row['sha256'],p
    assert (r/'fpga/palette_u8.bin').read_bytes()==bytes(((v*5+127)//255)*51 for v in range(256))
    assert bytes(int(v,16) for v in (r/'fpga/palette_u8.hex').read_text().split())==(r/'fpga/palette_u8.bin').read_bytes()
    c=json.loads((r/'fpga/deployment_contract.json').read_text(encoding='utf-8'));h=(r/'fpga/tinycomic_params.h').read_text()
    with np.load(r/'fpga/tinycomic_weights_int8.npz',allow_pickle=False) as z:
        assert np.array_equal(header(h,'tinycomic_shift'),[int(z[f'l{i}_shift']) for i in range(4)])
        for i,l in enumerate(c['layers']):
            for key,name,dtype in [('w','weights','s8'),('b','bias','s32')]:
                a=z[f'l{i}_{key}'];p=r/'fpga'/f'layer{i}_{name}_{dtype}.bin';assert p.read_bytes()==a.astype('<i4' if key=='b' else np.int8).tobytes()
                assert np.array_equal(header(h,f'tinycomic_l{i}_{key}'),a.ravel())
                hx=p.with_suffix('.hex').read_text().split();vals=np.array([int(v,16) for v in hx],dtype=np.uint32 if key=='b' else np.uint8)
                if key=='b':vals=vals.view(np.int32)
                else:vals=vals.view(np.int8)
                assert np.array_equal(vals,a.ravel())
            assert int(z[f'l{i}_shift'])==l['right_shift']
        for gd in sorted((r/'golden').iterdir()):
            rgb=np.asarray(Image.open(gd/'input.png').convert('RGB'));low=preprocess(rgb);out=infer_rgb(rgb,z)
            assert low.tobytes()==(gd/'pooled_rgb_edge_u8_hwc.bin').read_bytes()
            assert out.tobytes()==(gd/'expected_rgb_u8_hwc.bin').read_bytes()
            assert out.transpose(2,0,1).tobytes()==(gd/'expected_rgb_u8_chw.bin').read_bytes()
            assert np.array_equal(out,np.asarray(Image.open(gd/'expected.png')))
            _,ls,_=infer_low(low,z,True)
            for i,x in enumerate(ls):assert x.tobytes()==(gd/f'layer{i}_u8_hwc.bin').read_bytes()
    print(json.dumps({'status':'PASS','manifest_files':len(m['files']),'golden_frames':2,'weight_bin_hex_npz_header_equal':True,'preprocess_layer_and_final_exact':True,'board_verified':False}))
if __name__=='__main__':main()
