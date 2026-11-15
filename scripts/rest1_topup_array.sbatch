#!/bin/bash
set -eo pipefail
umask 077
export FSLDIR=/nas/longleaf/apps/fsl/5.0.10/fsl
source "$FSLDIR/etc/fslconf/fsl.sh"
export PATH="$FSLDIR/bin:$PATH" FSLOUTPUTTYPE=NIFTI_GZ OMP_NUM_THREADS=1
set -u

run=$1
data=$2
IFS=$'\t' read -r index direction relative < \
  <(sed -n "${SLURM_ARRAY_TASK_ID}p" "$run/tasks.tsv")

bold="$data/$relative"
stem=${bold%.nii.gz}
sbref="${stem}_SBRef.nii.gz"
prefix=${stem%_rfMRI_REST1_*}
se_ap="${prefix}_SpinEchoFieldMap1_AP.nii.gz"
se_pa="${prefix}_SpinEchoFieldMap1_PA.nii.gz"
for img in "$bold" "$sbref" "$se_ap" "$se_pa"; do
  [[ -r "$img" && -s "$img" ]]
done

out="$run/results/$index"
mkdir -p "$run/results"
mkdir "$out"
cd "$out"

python3 - "$direction" "$bold" "$sbref" "$se_ap" "$se_pa" > acqparams.txt <<'PY'
import json
import math
import sys
from pathlib import Path

direction, *paths = sys.argv[1:]
meta = [json.loads(Path(p.removesuffix(".nii.gz") + ".json").read_text())
        for p in paths]
pe = {"AP": "j-", "PA": "j"}[direction]
times = [float(m["TotalReadoutTime"]) for m in meta]
if ([m.get("PhaseEncodingDirection") for m in meta] != [pe, pe, "j-", "j"]
        or not all(math.isfinite(x) and x > 0 for x in times)
        or max(times) - min(times) > 1e-6):
    raise SystemExit("REVIEW: unexpected PE directions or readout times")
print(f"0 -1 0 {times[2]:.10g}")
print(f"0 1 0 {times[3]:.10g}")
PY

geometry() {
  fslhd "$1" | awk '
    /^(dim[1-3]|pixdim[1-3]|qform_code|sform_code|qto_xyz:[1-4]|sto_xyz:[1-4])[[:space:]]/ {
      $1=$1; print
    }'
}
geometry "$bold" > grid.txt
for img in "$sbref" "$se_ap" "$se_pa"; do
  [[ $(fslval "$img" dim4 | awk '{print $1}') == 1 ]]
  diff -u grid.txt <(geometry "$img")
done

fslmerge -t se_pair.nii.gz "$se_ap" "$se_pa"
topup --imain=se_pair.nii.gz --datain=acqparams.txt --config=b02b0.cnf \
  --out=topup_se --iout=se_unwarped --fout=field_hz \
  --dfout=se_warp --rbmout=se_motion --jacout=se_jac

slot=01
same_pe="$se_ap"
if [[ "$direction" == PA ]]; then
  slot=02
  same_pe="$se_pa"
fi

flirt -in "$sbref" -ref "$same_pe" -dof 6 -cost normmi \
  -omat sbref_to_se.mat
convert_xfm -omat sbref_to_topup_ref.mat \
  -concat "se_motion_$slot.mat" sbref_to_se.mat
flirt -in "$sbref" -ref "$same_pe" -applyxfm -init sbref_to_topup_ref.mat \
  -interp spline -datatype float -out sbref_before.nii.gz
convertwarp --relout --rel --ref="$same_pe" --premat=sbref_to_topup_ref.mat \
  --warp1="se_warp_$slot.nii.gz" --out=sbref_warp.nii.gz
applywarp --rel --interp=spline --datatype=float --in="$sbref" \
  --ref="$same_pe" --warp=sbref_warp.nii.gz --out=sbref_after.nii.gz
fslmaths sbref_after.nii.gz -mul "se_jac_$slot.nii.gz" \
  sbref_after_jac.nii.gz -odt float

upper=$(fslstats sbref_before.nii.gz -P 98 | awk '{print $1}')
awk -v x="$upper" 'BEGIN {exit !(x>0)}'
slicer sbref_before.nii.gz -i 0 "$upper" -a before.png
slicer sbref_after.nii.gz -i 0 "$upper" -a after.png
pngappend before.png + after.png qc_sbref.png
gzip -t sbref_warp.nii.gz sbref_after_jac.nii.gz
test -s qc_sbref.png
printf 'PASS: index=%s direction=%s TOPUP_slot=%s QC=%s/qc_sbref.png\n' \
  "$index" "$direction" "$slot" "$PWD"
