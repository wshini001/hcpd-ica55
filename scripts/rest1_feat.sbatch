#!/bin/bash
set -eo pipefail
umask 077
export FSLDIR=/nas/longleaf/apps/fsl/5.0.10/fsl
source "$FSLDIR/etc/fslconf/fsl.sh"
export PATH="$FSLDIR/bin:$PATH" FSLOUTPUTTYPE=NIFTI_GZ
set -u

run=$(realpath "$1")
bold=$(realpath "$2")
motion=$(realpath "$3")
sbref=$(realpath "$4")
anat=$(realpath "$5")
template=$(realpath "$6")
cd "$run"
[[ ! -e design.fsf && ! -e rest1_sdc.ica ]]
python3 - "$run" "$bold" "$motion" "$sbref" "$anat" "$template" <<'PY_FEAT'
import math
import os
import re
import sys
from pathlib import Path

run, bold, motion, sbref, anat, template = map(Path, sys.argv[1:])
names = ("T1_brain.nii.gz", "T1_brain_seg.nii.gz", "T1_brain_wmseg.nii.gz")
for path in (bold, motion, sbref, template, *(anat / name for name in names)):
    if not (path.is_file() and path.stat().st_size and os.access(path, os.R_OK)):
        raise SystemExit(f"REVIEW: missing or unreadable input: {path}")

rows = [line.split() for line in motion.read_text().splitlines()]
if len(rows) != 470 or any(
    len(row) != 6 or not all(math.isfinite(float(x)) for x in row) for row in rows
):
    raise SystemExit("REVIEW: PA motion must contain 470 rows of six finite values.")

pattern = re.compile(r"^\s*set\s+(\S+)\s+(.+)$")
lines = template.read_text().splitlines()
settings = {}
for line in lines:
    match = pattern.match(line)
    if match:
        settings[match[1]] = match[2].strip()

expected = dict(paradigm_hp=100, npts=470, tr=0.8, ndelete=0, mc=0, regunwarp_yn=0, smooth=0,
                reghighres_yn=1, regstandard_yn=1, regstandard_nonlinear_yn=1)
for name, value in expected.items():
    key = f"fmri({name})"
    if float(settings.get(key, "nan").strip('"')) != value:
        raise SystemExit(f"REVIEW: unexpected AP FEAT setting: {key}")

replacements = {
    "fmri(outputdir)": run / "rest1_sdc.ica",
    "feat_files(1)": bold,
    "alt_ex_func(1)": sbref,
    "highres_files(1)": run / "T1_brain.nii.gz",
}
if not replacements.keys() <= settings.keys():
    raise SystemExit("REVIEW: missing AP design input settings.")

updated = []
written = set()
for line in lines:
    match = pattern.match(line)
    if match and match[1] in replacements:
        key = match[1]
        if key not in written:
            updated.append(f'set {key} "{replacements[key]}"')
            written.add(key)
    else:
        if match and re.search(r"/(pilot|results|attempts)/|HCD[0-9]+", match[2]):
            raise SystemExit(f"REVIEW: unexpected visit-specific setting: {match[1]}")
        updated.append(line)

for name in names:
    (run / name).symlink_to(anat / name)
(run / "motion.par").symlink_to(motion)
(run / "design.fsf").write_text("\n".join(updated) + "\n")
print("PASS: motion is 470 × 6.", flush=True)
PY_FEAT

gzip -t -- "$sbref" T1_brain.nii.gz T1_brain_seg.nii.gz T1_brain_wmseg.nii.gz
[[ $(fslval "$bold" dim4 | awk '{print $1}') == 470 ]]
[[ $(fslval "$sbref" dim4 | awk '{print $1}') == 1 ]]
fslval "$bold" pixdim4 | awk 'NR==1 && $1>0.799999 && $1<0.800001 {ok=1}
                             END {exit !ok}'
echo 'PASS: FEAT inputs and acquisition settings verified.'
feat "$run/design.fsf"
printf 'FEAT launcher returned. Check %s/rest1_sdc.ica/report_log.html\n' "$run"
