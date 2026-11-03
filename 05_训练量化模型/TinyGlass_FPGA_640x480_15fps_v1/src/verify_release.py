from pathlib import Path
import argparse,json,hashlib,re
import numpy as np
from PIL import Image
from integer_reference import preprocess,infer_low,infer_rgb

def arr(text,name):
    m=re.search(r'\b'+name+r'\[(\d+)\]\s*=\s*\{([^}]+)\}',text);assert m,name
    a=np.array([int(s) for s in m[2].split(',')]);assert len(a)==int(m[1]),name;return a
def main():
    ap=argparse.ArgumentParser();ap.add_argument('--root',type=Path,default=Path(__file__).resolve().parents[1]);r=ap.parse_args().root
    manifest=json.loads((r/'MANIFEST.json').read_text(encoding='utf-8'))
    for f in manifest['files']:
        p=r/f['path'];assert p.stat().st_size==f['bytes'];assert hashlib.sha256(p.read_bytes()).hexdigest()==f['sha256'],p
    c=json.loads((r/'fpga/deployment_contract.json').read_text(encoding='utf-8'))
    gh=(r/'fpga/geometry.h').read_text();ph=(r/'fpga/tinyglass_params.h').read_text()
    with np.load(r/'fpga/geometry.npz',allow_pickle=False) as g,np.load(r/'fpga/tinyglass_weights_int8.npz',allow_pickle=False) as z:
        for k in ['dx','dy','lead']:
            signed=k!='lead';stem=f'geometry_{k}_'+('s8' if signed else 'u8');p=r/'fpga'/f'{stem}.bin'
            assert p.read_bytes()==g[k].tobytes();assert hashlib.sha256(p.read_bytes()).hexdigest()==c['preprocess']['geometry_ROMS'][k]['sha256']
            assert bytes(int(s,16) for s in p.with_suffix('.hex').read_text().split())==p.read_bytes();assert np.array_equal(arr(gh,f'tinyglass_{k}'),g[k].ravel())
        assert np.array_equal(arr(ph,'tinyglass_shift'),[int(z[f'l{i}_shift']) for i in range(3)])
        for i,l in enumerate(c['layers']):
            for k,field,dtype,fmt in [('w','weights','s8',np.int8),('b','bias','s32le','<i4')]:
                p=r/'fpga'/f'layer{i}_{field}_{dtype}.bin';a=np.fromfile(p,fmt);assert np.array_equal(a,z[f'l{i}_{k}'].ravel());assert np.array_equal(arr(ph,f'tinyglass_l{i}_{k}'),a)
                hx=bytes.fromhex(''.join(p.with_suffix('.hex').read_text().split()))
                if k=='b':hx=np.frombuffer(hx,'>u4').astype('<u4').tobytes()
                assert hx==p.read_bytes()
            assert int(z[f'l{i}_shift'])==l['right_shift']
        for gd in sorted((r/'golden').iterdir()):
            rgb=np.asarray(Image.open(gd/'input.png').convert('RGB'));low=preprocess(rgb,g);y=infer_rgb(rgb,z,g)
            assert rgb.tobytes()==(gd/'input_rgb_u8_hwc.bin').read_bytes();assert low.tobytes()==(gd/'mosaic_rgb_lead_u8_hwc.bin').read_bytes()
            assert np.array_equal(y,np.asarray(Image.open(gd/'expected.png')));assert y.tobytes()==(gd/'expected_rgb_u8_hwc.bin').read_bytes();assert y.transpose(2,0,1).tobytes()==(gd/'expected_rgb_u8_chw.bin').read_bytes()
            _,ys,_=infer_low(low,z,True)
            for i,a in enumerate(ys):assert a.tobytes()==(gd/f'layer{i}_u8_hwc.bin').read_bytes()
    print(json.dumps({'status':'PASS','manifest_files':len(manifest['files']),'golden_frames':2,'weights_and_geometry_bin_hex_npz_header_equal':True,'intermediate_final_exact':True,'board_verified':False}))
if __name__=='__main__':main()
