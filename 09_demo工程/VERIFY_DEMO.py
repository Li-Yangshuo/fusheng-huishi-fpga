from pathlib import Path
import hashlib
import json
import re
import sys
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parent
errors = []


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


manifest_path = ROOT / "MANIFEST_SHA256.json"
manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
listed = {entry["path"]: entry for entry in manifest["files"]}
for rel, entry in listed.items():
    path = ROOT / Path(rel)
    if not path.is_file():
        errors.append(f"missing: {rel}")
    elif path.stat().st_size != entry["bytes"] or sha(path) != entry["sha256"]:
        errors.append(f"hash mismatch: {rel}")
actual = {
    p.relative_to(ROOT).as_posix()
    for p in ROOT.rglob("*")
    if p.is_file() and p != manifest_path and "__pycache__" not in p.parts
}
for rel in sorted(actual - listed.keys()):
    errors.append(f"unlisted: {rel}")
for rel in sorted(listed.keys() - actual):
    errors.append(f"listed but absent: {rel}")

project_root = ROOT / "project"
project_dir = project_root / "structure/board_r6/project"
xml_path = project_dir / "ti60f225_oob.xml"
tree = ET.parse(xml_path)
sources = []
for node in tree.findall(".//{*}design_file"):
    path = (project_dir / node.attrib["name"]).resolve()
    sources.append(path)
    if not path.is_file():
        errors.append(f"missing design source: {node.attrib['name']}")
for tag in ("default_peri_file", "peri_file", "sdc_file"):
    for node in tree.findall(f".//{{*}}{tag}"):
        path = (project_dir / node.attrib["name"]).resolve()
        if not path.is_file():
            errors.append(f"missing {tag}: {node.attrib['name']}")

include_roots = [project_dir, project_dir / "rtl", project_dir / "rtl/ddr3_controller",
                 project_dir / "rtl/cam_i2c_ctrl/i2c_master"]
visited = set()
queue = list(sources)
while queue:
    source = queue.pop()
    if source in visited or not source.is_file() or source.suffix.lower() not in {".v", ".sv", ".vh", ".svh"}:
        continue
    visited.add(source)
    text = source.read_text(encoding="utf-8-sig", errors="replace")
    clean = re.sub(r"/\*.*?\*/", "", text, flags=re.S)
    clean = re.sub(r"//[^\n]*", "", clean)
    for name in re.findall(r'`include\s+"([^"]+)"', clean):
        found = next((p for p in [source.parent / name] + [r / name for r in include_roots] if p.is_file()), None)
        if found is None:
            errors.append(f"unresolved include: {source.relative_to(project_root)} -> {name}")
        else:
            queue.append(found.resolve())
    for expr in re.findall(r"\$readmem[hb]\s*\(\s*([^,]+),", clean):
        expr = expr.strip()
        if expr.startswith('"') and expr.endswith('"'):
            name = expr[1:-1]
            found = next((p for p in [source.parent / name, project_dir / name] if p.is_file()), None)
            if found is None:
                errors.append(f"unresolved readmem: {source.relative_to(project_root)} -> {name}")

# Verify the compiler/INIT and PNR binding recorded for this branch against the delivered source copy.
binding_path = ROOT / "verification/build_20261103_014153/SOURCE_BINDINGS_FINAL.json"
bindings = json.loads(binding_path.read_text(encoding="utf-8"))
for rel, expected in bindings.items():
    normalized = rel.replace("\\", "/")
    path = project_root / Path(normalized)
    if not path.is_file():
        errors.append(f"bound source absent: {rel}")
    elif sha(path) != expected:
        errors.append(f"bound source changed: {rel}")

bit_path = ROOT / "BIT/ti60f225_oob_m7_riscv_r8.bit"
bit_info = json.loads((ROOT / "BIT_INFO.json").read_text(encoding="utf-8"))
if not bit_path.is_file() or bit_path.stat().st_size != bit_info["bytes"] or sha(bit_path) != bit_info["sha256"]:
    errors.append("BIT size or SHA-256 mismatch")

required_results = ["r8_system", "hd_pp", "display_encoder", "scanout_style0", "ui"]
for name in required_results:
    result_path = ROOT / f"verification/{name}/RESULTS.json"
    if not result_path.is_file():
        errors.append(f"missing verification result: {name}")
    else:
        result = json.loads(result_path.read_text(encoding="utf-8"))
        if result.get("status") != "PASS":
            errors.append(f"verification not PASS: {name}")

report = {
    "status": "PASS" if not errors else "FAIL",
    "manifest_files": len(listed),
    "xml_sources": len(sources),
    "resolved_source_includes": len(visited),
    "bound_sources": len(bindings),
    "required_regressions": len(required_results),
    "bit_sha256": bit_info["sha256"],
    "errors": errors,
}
print(json.dumps(report, ensure_ascii=False, indent=2))
sys.exit(bool(errors))

