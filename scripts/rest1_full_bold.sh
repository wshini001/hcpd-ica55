#!/bin/bash
#SBATCH --job-name=hcpd_pa_full
#SBATCH --partition=interact
#SBATCH --account=rc_htzhu_pi
#SBATCH --qos=normal
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=1
#SBATCH --mem=12G
#SBATCH --time=04:00:00

set -eo pipefail
umask 077
export FSLDIR=/nas/longleaf/apps/fsl/5.0.10/fsl
source "$FSLDIR/etc/fslconf/fsl.sh"
export PATH="$FSLDIR/bin:$PATH" FSLOUTPUTTYPE=NIFTI_GZ OMP_NUM_THREADS=1
set -u

run=$1
bold=$2
sbref=$3
topup_run=$4
slot=$5
ref="$topup_run/sbref_after.nii.gz"
warp="$topup_run/sbref_warp.nii.gz"
jac="$topup_run/se_jac_${slot}.nii.gz"
expected="$topup_run/sbref_after_jac.nii.gz"

tmp=$(mktemp -d "${SLURM_TMPDIR:-${TMPDIR:-/tmp}}/hcpd_pa_full_XXXXXX")
trap 'rm -rf -- "$tmp"' EXIT
cd "$tmp"

nraw=$(fslval "$bold" dim4 | awk '{print $1}')
tr=$(fslval "$bold" pixdim4 | awk '{print $1}')
[[ "$nraw" == 478 ]]
awk -v tr="$tr" 'BEGIN {exit !(tr > 0.799999 && tr < 0.800001)}'
discard=8
nkeep=$((nraw - discard))
printf 'PA input: %s frames, TR=%s s, discard=%s, keep=%s\n' \
  "$nraw" "$tr" "$discard" "$nkeep"

applywarp --rel --interp=spline --datatype=float \
  --in="$sbref" --ref="$ref" --warp="$warp" --out=sbref_replay.nii.gz
fslmaths sbref_replay.nii.gz -mul "$jac" sbref_replay_jac.nii.gz -odt float
fslmaths sbref_replay_jac.nii.gz -sub "$expected" -abs sbref_diff.nii.gz
max_diff=$(fslstats sbref_diff.nii.gz -R | awk '{print $2}')
signal=$(fslstats "$expected" -P 98 | awk '{print $1}')
awk -v d="$max_diff" -v s="$signal" 'BEGIN {
  printf "SBRef replay: max absolute difference=%s, reference P98=%s\n", d, s
  exit !(s > 0 && d >= 0 && d <= 0.00001 * s)
}'
echo 'PASS: saved SBRef correction reproduced.'

fslroi "$bold" kept.nii.gz "$discard" "$nkeep"
mcflirt -in kept.nii.gz -reffile "$sbref" -out mc -mats -plots
awk -v n="$nkeep" 'NF != 6 {exit 1} END {if (NR != n) exit 1}' mc.par
fslsplit kept.nii.gz raw_ -t

frames=()
for ((i=0; i<nkeep; i++)); do
  printf -v index '%04d' "$i"
  matrix="mc.mat/MAT_$index"
  [[ -s "$matrix" ]]
  applywarp --rel --interp=spline --datatype=float \
    --in="raw_$index.nii.gz" --ref="$ref" --premat="$matrix" \
    --warp="$warp" --out=warped.nii.gz
  corrected="corrected_$index.nii.gz"
  fslmaths warped.nii.gz -mul "$jac" "$corrected" -odt float
  frames+=("$corrected")
  if (((i + 1) % 50 == 0 || i + 1 == nkeep)); then
    printf 'Corrected %d/%d frames\n' "$((i + 1))" "$nkeep"
  fi
done

fslmerge -tr "$run/bold_sdc.nii.gz" "${frames[@]}" "$tr"
gzip -t "$run/bold_sdc.nii.gz"
[[ "$(fslval "$run/bold_sdc.nii.gz" dim4 | awk '{print $1}')" == "$nkeep" ]]
out_tr=$(fslval "$run/bold_sdc.nii.gz" pixdim4 | awk '{print $1}')
awk -v a="$out_tr" -v b="$tr" 'BEGIN {exit !(a-b < 1e-6 && b-a < 1e-6)}'
cp mc.par "$run/motion.par"

fslmaths mc.nii.gz -Tmean "$run/mean_motion_only.nii.gz"
fslmaths "$run/bold_sdc.nii.gz" -Tmean "$run/mean_sdc.nii.gz"
upper=$(fslstats "$run/mean_motion_only.nii.gz" -P 98 | awk '{print $1}')
awk -v x="$upper" 'BEGIN {exit !(x > 0)}'
slicer "$run/mean_motion_only.nii.gz" -i 0 "$upper" -a before.png
slicer "$run/mean_sdc.nii.gz" -i 0 "$upper" -a after.png
pngappend before.png + after.png "$run/qc_full_mean.png"
test -s "$run/qc_full_mean.png"
printf 'PASS: corrected BOLD has %s frames at TR=%s s.\n' "$nkeep" "$out_tr"
printf 'Motion rows: %s\nQC image: %s\n' \
  "$(wc -l < "$run/motion.par")" "$run/qc_full_mean.png"
