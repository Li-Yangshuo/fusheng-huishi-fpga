"""Portable evidence/source binding verifier; never opens or programs hardware."""
from pathlib import Path
import json,hashlib,re
from review_gc import review
R=Path(__file__).resolve().parents[1]
NEW=['exact_dual_core/glass','exact_dual_core/comic','gc_keys','gc_display_encoder',
     'gc_scanout15_switch','gc_scanout15_comic_final6','gc_scanout15_glass_final6']
REUSED=['capture','color_fps_hd6','cpu_boot_hd6','model_reference']
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()

def verify():
    review_result=review(write_receipts=False)
    nbindings=0;results={}
    for name in NEW+REUSED:
        d=json.loads((R/f'evidence/{name}/RESULTS.json').read_text(encoding='utf-8'))
        assert d['status']=='PASS',name
        for n,h in d['source_sha256'].items():
            p=Path(n)
            if p.is_absolute():
                normalized=n.replace('\\','/')
                marker='glass_comic_hd6_m8_exact_20261101/'
                if marker in normalized:p=R/normalized.split(marker,1)[1]
                elif normalized=='C:/Efinity/2026.1/sim_models/verilog/efx_srl8.v':p=R/'verification/toolchain/efx_srl8.v'
                else:raise AssertionError(('unrelocatable source',n))
            else:p=R/p
            assert p.is_file() and sha(p)==h,('stale test input',name,n)
            nbindings+=1
        results[name]=dict(status='PASS',classification='current integration' if name in NEW else 'reused unchanged submodule; not new full-board proof',receipts=d.get('receipts',[]))
    top=(R/'structure/board_r6/project/rtl/ti60f225_oob_top.v').read_text(encoding='utf-8')
    control=top[top.index(' wire [1:0] demo_mode;'):top.index(' wire [31:0] right_pixel_model,nn_result_model;')]
    control_sha=hashlib.sha256(control.encode()).hexdigest()
    assert json.loads((R/'evidence/gc_keys/RESULTS.json').read_text())['production_control_sha256']==control_sha
    for name in NEW[3:]:
        d=json.loads((R/f'evidence/{name}/RESULTS.json').read_text())
        assert d['production_key_control_sha256']==control_sha
    encoder=json.loads((R/'evidence/gc_display_encoder/RESULTS.json').read_text())
    fragment=top[top.index('wire fs,hs,vs,de;'):top.index('assign tmds_tx_clk_TX_DATA')]
    assert hashlib.sha256(fragment.encode()).hexdigest()==encoder['production_display_fragment_sha256']
    for name in NEW[-3:]:
        d=json.loads((R/f'evidence/{name}/RESULTS.json').read_text())
        for n in ['hd_weights.mem','hd_bias.mem','hd_geometry.mem','comic_weights.mem','comic_bias.mem']:
            assert sha(R/f'evidence/{name}/{n}')==sha(R/f'structure/board_r6/project/{n}')
        log=(R/f'evidence/{name}/simulate.log').read_text(encoding='utf-8',errors='replace')
        assert 'SCANOUT_SERVICE PASS' in log and 'HD720_RATE PASS' in log
        steady=float(re.search(r'nn_steady_fps=([\d.]+)',log).group(1))
        job=int(re.search(r'HD720_RATE PASS.*max_job_cycles=(\d+)',log).group(1))
        assert steady>=14.95 and job<=6666666
    # Include a portable record of exactly the vectors consumed by each original
    # test. The archived absolute-path TB is immutable; replay_exact_gc.py
    # rewrites only those paths into a new simulation directory when rerunning.
    vectors=json.loads((R/'evidence/GC_VECTOR_BINDINGS.json').read_text(encoding='utf-8'))
    for n,h in vectors.items():assert sha(R/n)==h,('vector changed',n)
    res=dict(status='PASS',test_count=len(results),tests=results,source_bindings_checked=nbindings,
        vector_bindings_checked=len(vectors),implementation=review_result,
        physical_board_verified=False,physical_15fps_verified=False)
    return res

if __name__=='__main__':
    result=verify()
    (R/'evidence/GC_EVIDENCE_REVIEW.json').write_text(json.dumps(result,indent=2),encoding='utf-8')
    print('GC_EVIDENCE PASS',result['test_count'],'tests;',result['source_bindings_checked'],'source bindings')
