#!/bin/bash -l
set -eo pipefail
umask 077

export FSLDIR=/nas/longleaf/apps/fsl/5.0.10/fsl
source "$FSLDIR/etc/fslconf/fsl.sh"
export PATH="$FSLDIR/bin:$PATH" FSLOUTPUTTYPE=NIFTI_GZ
export OMP_NUM_THREADS=1 OPENBLAS_NUM_THREADS=1 MKL_NUM_THREADS=1
export HCPD_ICA55_UKB="${HCPD_ICA55_UKB:?Set the UKB pipeline root}"
set -u

bold=$(realpath "$1")
out=$(realpath "$2")
code="${HCPD_SCRIPTS:?}/extract_netmats.m"
map="$HCPD_ICA55_UKB/templates/group/rfMRI_ICA_d100.nii.gz"
mask="$FSLDIR/data/standard/MNI152_T1_2mm_brain_mask.nii.gz"
matlab_bin=${MATLAB_BIN:-/nas/longleaf/rhel9/apps/matlab/2024b/bin/matlab}
for file in "$bold" "$code" "$map" "$mask"; do test -s "$file"; done
cd "$out"
grid() {
  fslhd "$1" | awk '
    /^(dim[1-3]|pixdim[1-3]|[qs]form_code|qto_xyz:[1-4]|sto_xyz:[1-4])[[:space:]]/ {
      printf "%s", $1
      for (i=2; i<=NF; i++) printf " %.6f", ($i + 0)
      print ""
    }'
}

[[ $(fslval "$bold" dim4 | awk '{print $1}') == 470 ]]
[[ $(fslval "$map" dim4 | awk '{print $1}') == 100 ]]
[[ $(fslval "$mask" dim4 | awk '{print $1}') == 1 ]]
fslval "$bold" pixdim4 | awk 'NR==1 && $1>0.799999 && $1<0.800001 {ok=1} END {exit !ok}'
diff -u <(grid "$bold") <(grid "$map")
diff -u <(grid "$bold") <(grid "$mask")
mkdir rfMRI_100.dr
fsl_glm -i "$bold" -d "$map" -m "$mask" --demean -o rfMRI_100.dr/dr_stage1.txt
cp -- "$code" .
"$matlab_bin" -batch extract_netmats
