"""Verify a freshly extracted package, including all recorded file hashes."""
from pathlib import Path
import json,hashlib
R=Path(__file__).resolve().parents[1]
def verify():
    manifest=json.loads((R/'MANIFEST_SHA256.json').read_text(encoding='utf-8'))
    actual={p.relative_to(R).as_posix() for p in R.rglob('*') if p.is_file() and '__pycache__' not in p.parts and p.name!='MANIFEST_SHA256.json'}
    assert actual==set(manifest),('manifest file list differs',list(actual-set(manifest))[:5],list(set(manifest)-actual)[:5])
    for n,v in manifest.items():
        p=R/n
        assert p.stat().st_size==v['bytes'] and hashlib.sha256(p.read_bytes()).hexdigest()==v['sha256'],n
    from verify_gc_evidence import verify as verify_evidence
    evidence=verify_evidence()
    d=json.loads((R/'DELIVERY_STATUS.json').read_text(encoding='utf-8'))
    bit=R/d['BIT']['file']
    assert hashlib.sha256(bit.read_bytes()).hexdigest()==d['BIT']['sha256']
    for n in ['peri.cdo','peri.pbn','peri.csi','peri.qdelay','pinout.csv','timing.rpt','raminfo.pb']:
        assert (R/f'structure/board_r6/project/outflow/ti60f225_oob.{n}').is_file()
    print('GC_PACKAGE PASS files='+str(len(manifest))+' tests='+str(evidence['test_count'])+' board_verified=False')
if __name__=='__main__':verify()
