from pathlib import Path
import urllib.request, tarfile, hashlib, json, time
root=Path(__file__).resolve().parent
archive=root/'BSR_bsds500.tgz'
url='https://www2.eecs.berkeley.edu/Research/Projects/CS/vision/grouping/BSR/BSR_bsds500.tgz'
if not archive.exists():
    print('Downloading BSDS500',url,flush=True)
    urllib.request.urlretrieve(url, archive)
dest=root/'bsds500'
dest.mkdir(exist_ok=True)
with tarfile.open(archive) as tf:
    members=[m for m in tf.getmembers() if m.isfile() and '/data/images/' in m.name and m.name.endswith('.jpg')]
    for m in members:
        split=Path(m.name).parts[-2]
        p=dest/split/Path(m.name).name
        p.parent.mkdir(exist_ok=True)
        p.write_bytes(tf.extractfile(m).read())
manifest={'url':url,'archive_sha256':hashlib.sha256(archive.read_bytes()).hexdigest(),
          'split_counts':{s:len(list((dest/s).glob('*.jpg'))) for s in ['train','val','test']},
          'training':'official train + val; test never used for optimization or checkpoint selection',
          'files':[{ 'split':p.parent.name,'name':p.name,'sha256':hashlib.sha256(p.read_bytes()).hexdigest()} for p in sorted(dest.rglob('*.jpg'))]}
(dest/'manifest.json').write_text(json.dumps(manifest,indent=2),encoding='utf-8')
print(json.dumps({k:v for k,v in manifest.items() if k!='files'}),flush=True)
