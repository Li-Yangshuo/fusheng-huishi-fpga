"""Curate the exact HD6/M8 release and verify a fresh ZIP extraction."""
from pathlib import Path
import hashlib,json,shutil,zipfile,subprocess,sys,re
from verify_gc_evidence import verify,NEW,REUSED
R=Path(__file__).resolve().parents[1];AB=R.parents[1]
NAME='GLASS_COMIC_HD6_M8_720P15_KEY12_20261101_R1'
D=AB/'outputs'/NAME;Z=D.with_suffix('.zip')
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()

def copy(src,dst):
    dst.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(src,dst)

def prepare_vector_bindings():
    paths=[]
    for name in ['hd_glass','comic_engine_1280x720']:
        vector=R/f'evidence/{name}/vectors'
        for case in range(4):
            for p in sorted(vector.glob(f'case{case}_*.hex')):
                # The original M8 test used a different checkout. Prove that
                # this package's vectors are exactly those consumed there.
                if name=='comic_engine_1280x720':
                    old=AB/'branches/tinycomic_m8/evidence/comic_engine_1280x720/vectors'/p.name
                    assert sha(old)==sha(p),p
                paths.append(p)
    for case in range(4):
        assert sha(R/f'evidence/hd_glass/vectors/case{case}_input.hex')==sha(R/f'evidence/comic_engine_1280x720/vectors/case{case}_input.hex')
    for name in NEW[-3:]:paths.extend(sorted((R/f'evidence/{name}/vectors').glob('*.hex')))
    values={p.relative_to(R).as_posix():sha(p) for p in paths}
    (R/'evidence/GC_VECTOR_BINDINGS.json').write_text(json.dumps(values,indent=2),encoding='utf-8')

def main():
    assert not D.exists() and not Z.exists(),'never overwrite a release'
    # Describe the completed test scope precisely; fixed-style6-frame tests
    # complement, rather than repeat, the12-frame all-layout switch regression.
    for name in NEW[-2:]:
        p=R/f'evidence/{name}/RESULTS.json'
        d=json.loads(p.read_text(encoding='utf-8'))
        assert d['status']=='PASS' and d['frames']==6
        d.update(scope='Fixed original '+('M8 Comic' if d['style']==0 else 'HD6 Glass')+' with both original cores instantiated, actual service and production key control, DDR BFM random stalls and24..32cycle latency, native720 processing plus720p60 scanout. All6 unique frames and every displayed pixel checked. Rate uses commits3..6 to separate startup; layouts covered during these6frames only. All4 layouts and both model/layout combinations separately covered by12-frame mixed-style regression.',startup_commits_excluded_from_rate_only=2,steady_commit_count=4)
        p.write_text(json.dumps(d,indent=2),encoding='utf-8')
    prepare_vector_bindings()
    verified=verify()
    (R/'evidence/GC_EVIDENCE_REVIEW.json').write_text(json.dumps(verified,indent=2),encoding='utf-8')
    review=verified['implementation']
    allowed_tools={'build.py','split_boot_lanes.py','verify_cpu_ram_init.py','verify_model_init.py','verify_hd2_bias_logic.py','verify_comic_init.py','review_gc.py','verify_gc_evidence.py','verify_gc_package.py','replay_exact_gc.py','recover_gc_fixed.py','run_gc_display.py','run_gc_scanout.py','run_capture.py','run_color_fps.py','run_cpu_boot.py','run_model_reference.py'}
    for directory in ['structure','references','verification']:
        for p in (R/directory).rglob('*'):
            if not p.is_file():continue
            if any(x in {'__pycache__','work','work_syn','work_pt'} for x in p.parts):continue
            if 'work_pnr' in p.parts and p.name!='ti60f225_oob.lbf':continue
            if p.name.startswith('initial_'):continue
            copy(p,D/p.relative_to(R))
    # Only RTL in the bound production project, plus the retained WB meter test.
    build=R/'evidence'/review['build']
    bound=json.loads((build/'SOURCE_BINDINGS.json').read_text(encoding='utf-8'))
    for n in bound:
        p=R/n
        if p.relative_to(R).parts[0]=='rtl':copy(p,D/p.relative_to(R))
    copy(R/'rtl/pp2_fps_meter.sv',D/'rtl/pp2_fps_meter.sv')
    for n in allowed_tools:copy(R/'tools'/n,D/'tools'/n)
    copy(Path(__file__),D/'tools/package_gc.py')
    for name in ['TinyGlass','TinyComic']:
        for p in (R/'model'/name).rglob('*'):
            if p.is_file() and '__pycache__' not in p.parts:copy(p,D/p.relative_to(R))
    for name in NEW+REUSED+['style_preview',review['build']]:
        for p in (R/'evidence'/name).rglob('*'):
            if not p.is_file():continue
            if any(x in {'work','__pycache__'} for x in p.parts):continue
            if p.suffix=='.wlf' or p.name in {'modelsim.ini','transcript'}:continue
            copy(p,D/p.relative_to(R))
    vector_bindings=json.loads((R/'evidence/GC_VECTOR_BINDINGS.json').read_text(encoding='utf-8'))
    for n in vector_bindings:copy(R/n,D/n)
    for n in ['GC_VECTOR_BINDINGS.json','GC_IMPLEMENTATION_REVIEW.json','GC_EVIDENCE_REVIEW.json','GC_CPU_MAP_INIT.json','GC_GLASS_MAP_INIT.json','GC_COMIC_MAP_INIT.json','LATEST_BUILD.txt']:
        copy(R/'evidence'/n,D/'evidence'/n)
    # The unchanged CPU boot test uses the default Glass MMIO identity. Keep
    # that legacy fixture under its own explicit scope, not as a two-model claim.
    boot_binding=json.loads((R/'evidence/MODEL_BINDING.json').read_text(encoding='utf-8'))
    boot_binding['scope']='Inherited default-Glass CPU boot fixture only; current dual-model release identity is DELIVERY_STATUS.json and references/SOURCE_AUDIT.json.'
    (D/'evidence/MODEL_BINDING.json').write_text(json.dumps(boot_binding,indent=2),encoding='utf-8')
    for n in ['README_GC.zh-CN.md','BOARD_BRINGUP_GC.zh-CN.md','REFERENCE_BITS.json']:copy(R/n,D/n)
    P=D/'structure/board_r6/project'
    for ext in ['bit','hex']:copy(P/f'outflow/ti60f225_oob_gc_exact.{ext}',D/f'BIT/GlassComic_HD6_M8.{ext}')
    copy(P/'work_pnr/ti60f225_oob.lbf',D/'BIT/ti60f225_oob.lbf')
    refs=json.loads((R/'REFERENCE_BITS.json').read_text(encoding='utf-8'))
    for name,value in refs.items():
        target=D/f'rollback/{name}_{"HD6" if name=="Glass" else "M8"}_original.bit'
        copy(Path(value['path']),target);assert sha(target)==value['sha256']
    performance={}
    for name in NEW[-3:]:
        log=(R/f'evidence/{name}/simulate.log').read_text(encoding='utf-8',errors='replace')
        test=json.loads((R/f'evidence/{name}/RESULTS.json').read_text())
        perf=dict(style=test['style'],frames=test['frames'])
        line=next(s for s in log.splitlines() if 'HD720_RATE PASS' in s)
        for key in ['left_fps','right_fps','nn_fps','max_job_cycles','max_commit_gap']:
            v=re.search(key+r'=([\d.]+)',line).group(1);perf[key]=float(v) if '.' in v else int(v)
        perf['nn_steady_fps']=float(re.search(r'nn_steady_fps=([\d.]+)',log).group(1))
        preview=re.search(r'HD720_PREVIEW_STEADY left_fps=([\d.]+) right_fps=([\d.]+)',log)
        if preview:perf.update(left_steady_fps=float(preview.group(1)),right_steady_fps=float(preview.group(2)))
        perf['read_latency_cycles']=[24,32];perf['input_fps']=15;perf['physical_measurement']=False
        performance[name]=perf
    status=dict(status='READY_FOR_JTAG_BOARD_TRIAL',models=['original_HD6_Glass','original_M8_Comic'],
        reset_model='Glass',reset_layout='original_fullscreen',
        KEY1_layouts=['original_fullscreen','same_scene_left_original_right_rendered','rendered_fullscreen','complete_same_scene_pair_full_height'],
        KEY2_style_cycle=['Glass','Comic'],keys=review['keys'],debounce_ms=10,
        physical_KEY2_verified=False,HDMI_WH_Hz=[1280,720,60],native_processing_WH=[1280,720],
        preview_WH=[640,360],native_detail_scanout=False,small_pair_display_WH_each=[640,720],small_pair_vertical_stretch=True,
        white_balance=True,OSD=['1280X720','FPS:xx.x'],FPS_source='8 actual successful completion intervals at100MHz, rounded0.1, zero after1s without result',
        artificial_FPS_variation=False,target_results_fps=15,performance_simulation=performance,
        resources=review['resources'],worst_setup_ns=review['worst_setup_ns'],worst_hold_ns=review['worst_hold_ns'],
        tests=NEW,reused_unchanged_submodule_tests=REUSED,physical_board_verified=False,physical_15fps_verified=False,flash_programmed=False,
        BIT=dict(file='BIT/GlassComic_HD6_M8.bit',bytes=(D/'BIT/GlassComic_HD6_M8.bit').stat().st_size,sha256=sha(D/'BIT/GlassComic_HD6_M8.bit')),
        references=refs)
    (D/'DELIVERY_STATUS.json').write_text(json.dumps(status,indent=2),encoding='utf-8')
    files=sorted(p for p in D.rglob('*') if p.is_file())
    manifest={p.relative_to(D).as_posix():dict(bytes=p.stat().st_size,sha256=sha(p)) for p in files}
    (D/'MANIFEST_SHA256.json').write_text(json.dumps(manifest,indent=2),encoding='utf-8')
    def check(folder):
        q=subprocess.run([sys.executable,'-X','utf8',folder/'tools/verify_gc_package.py'],capture_output=True,text=True)
        assert q.returncode==0,q.stdout+q.stderr
        print(q.stdout,flush=True)
    check(D)
    with zipfile.ZipFile(Z,'w',zipfile.ZIP_DEFLATED,compresslevel=6) as z:
        for p in D.rglob('*'):
            if p.is_file() and '__pycache__' not in p.parts:z.write(p,(Path(NAME)/p.relative_to(D)).as_posix())
    fresh=AB/'work'/f'{NAME}_fresh_verify';fresh.mkdir(parents=True,exist_ok=False)
    with zipfile.ZipFile(Z) as z:
        assert z.testzip() is None and {Path(n).parts[0] for n in z.namelist()}=={NAME}
        z.extractall(fresh)
    check(fresh/NAME)
    desktop=Path('C:/Users/Lenovo/Desktop')/NAME;desktop.mkdir(exist_ok=False)
    for n in ['BIT/GlassComic_HD6_M8.bit','README_GC.zh-CN.md','BOARD_BRINGUP_GC.zh-CN.md','DELIVERY_STATUS.json','evidence/style_preview/Original_Glass_Comic_case1.png']:
        copy(D/n,desktop/n);assert sha(D/n)==sha(desktop/n)
    copy(Z,desktop/Z.name);assert sha(Z)==sha(desktop/Z.name)
    result=dict(status='PASS',output_directory=str(D),desktop=str(desktop),zip=str(Z),zip_bytes=Z.stat().st_size,zip_sha256=sha(Z),
        bit=str(desktop/'BIT/GlassComic_HD6_M8.bit'),bit_sha256=status['BIT']['sha256'],manifest_files=len(manifest),fresh_extract_verified=True,
        one_top_level_folder=True,physical_board_verified=False,physical_15fps_verified=False)
    (AB/'outputs'/f'{NAME}_VERIFICATION.json').write_text(json.dumps(result,indent=2),encoding='utf-8')
    print(json.dumps(result,indent=2),flush=True)
if __name__=='__main__':main()
