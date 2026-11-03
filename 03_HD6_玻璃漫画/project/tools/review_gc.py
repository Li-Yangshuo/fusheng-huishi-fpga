"""Review the exact HD6/M8 full-board build, independently of inherited reviews."""
from pathlib import Path
import hashlib, json, re, xml.etree.ElementTree as ET
from verify_cpu_ram_init import verify as cpu_verify
from verify_model_init import verify as glass_verify
from verify_comic_init import verify as comic_verify

R = Path(__file__).resolve().parents[1]
P = R / 'structure/board_r6/project'
F = P / 'outflow'
sha = lambda p: hashlib.sha256(p.read_bytes()).hexdigest()

def review(write_receipts=True):
    build = (R/'evidence/LATEST_BUILD.txt').read_text(encoding='utf-8').strip()
    B = R/'evidence'/build
    result = json.loads((B/'RESULTS.json').read_text(encoding='utf-8'))
    assert [x['stage'] for x in result['stages']] == ['interface','map','pnr','pgm']
    assert all(x['returncode'] == 0 for x in result['stages'])
    bindings = json.loads((B/'SOURCE_BINDINGS.json').read_text(encoding='utf-8'))
    assert all(sha(R/n) == h for n,h in bindings.items()), 'stale build sources'
    xml = ET.parse(P/'ti60f225_oob.xml')
    sources = [(P/e.attrib['name']).resolve() for e in xml.findall('.//{*}design_file')]
    assert len(sources) == 80
    for p in sources:
        assert p.is_relative_to(R) and bindings[str(p.relative_to(R))] == sha(p)
    timing = (F/'ti60f225_oob.timing.rpt').read_text(encoding='utf-8')
    def slacks(kind):
        text = timing.split(f'Path Details for {kind} Critical Paths (begin)')[1].split(f'Path Details for {kind} Critical Paths (end)')[0]
        return [float(x) for x in re.findall(r'Slack\s*:\s*([-+]?\d+\.\d+)',text)]
    setup, hold = slacks('Max'), slacks('Min')
    assert setup and hold and min(setup) >= 0 and min(hold) >= 0
    place = (F/'ti60f225_oob.place.rpt').read_text(encoding='utf-8')
    resources = {}
    for label,key in [('XLRs','XLR'),('Memory Blocks','RAM10'),('DSP Blocks','DSP')]:
        used,cap = map(int,re.search(label+r': (\d+) / (\d+)',place).groups())
        assert used <= cap
        resources[key] = dict(used=used,capacity=cap,percent=round(100*used/cap,2))
    pins = (F/'ti60f225_oob.pinout.csv').read_text(encoding='utf-8')
    for pin,gpio,signal in [('P14','GPIOR_22','i_view_key_n'),('N14','GPIOR_21','i_style_key_n')]:
        assert f'{pin},{gpio},{signal},Input' in pins
    for name,fn in [('CPU',cpu_verify),('GLASS',glass_verify),('COMIC',comic_verify)]:
        value = fn(F/'ti60f225_oob.raminfo.pb',P/'cpu_boot.mem') if name=='CPU' else fn(P)
        if write_receipts:(R/f'evidence/GC_{name}_MAP_INIT.json').write_text(json.dumps(value,indent=2),encoding='utf-8')
    reference = json.loads((R/'references/SOURCE_AUDIT.json').read_text(encoding='utf-8'))
    assert reference['status'] == 'PASS'
    for n,h in reference['source_sha256'].items():
        assert sha(R/n) == h, ('reference source drift',n)
    bit = F/'ti60f225_oob_gc_exact.bit'
    assert sha(bit) == 'bb0970c95b19fcf060efcd93821347ba4df4fdb5c0659e4d2b563bf420ec924d'
    artifacts = [bit,F/'ti60f225_oob_gc_exact.hex',P/'work_pnr/ti60f225_oob.lbf']
    # Efinity appends old failures to err.log. Check the bound current map log
    # instead, and retain the cumulative log with this provenance explained.
    current_map = (B/'map.log').read_text(encoding='utf-8',errors='replace')
    assert not re.search(r'\[EFX-\d+ (?:VERI-ERROR|ERROR)\]',current_map)
    res = dict(status='PNR_BIT_TIMING_CAPACITY_PASS',build=build,HDL_sources=80,
        source_bindings_checked=len(bindings),resources=resources,
        worst_setup_ns=min(setup),worst_hold_ns=min(hold),setup_reported_paths=len(setup),
        hold_reported_paths=len(hold),negative_reported_paths=0,core_clock_MHz=100,
        HDMI_WH_Hz=[1280,720,60],native_processing_WH=[1280,720],preview_WH=[640,360],
        native_detail_scanout=False,target_results_fps=15,
        keys={'KEY1':'P14/GPIOR_22','KEY2':'N14/GPIOR_21'},
        cdc_no_synchronizer_warnings='No Synchronizer warnings to report.' in (F/'ti60f225_oob.cdc.rpt').read_text(encoding='utf-8'),
        inherited_missing_interface_pins=['mipi_dp_data0_LP_P_IN','mipi_dp_data0_LP_N_IN','vid_clk_dvi2'],
        accumulated_err_log_contains_superseded_attempts=True,
        comic_bias_gate_level_independent_proof=False,
        physical_board_verified=False,physical_15fps_verified=False,flash_programmed=False,
        artifacts={p.relative_to(R).as_posix():dict(bytes=p.stat().st_size,sha256=sha(p)) for p in artifacts})
    if write_receipts:(R/'evidence/GC_IMPLEMENTATION_REVIEW.json').write_text(json.dumps(res,indent=2),encoding='utf-8')
    return res

if __name__ == '__main__':
    print(json.dumps(review(),indent=2))
