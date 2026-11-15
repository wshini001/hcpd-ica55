#!/usr/bin/env bash
#SBATCH --job-name=hcpd_ants_seg
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=3
#SBATCH --mem=24000M
#SBATCH --time=23:59:59
set -eo pipefail
umask 077

run=$1
ants=$2
ants_bin=$3
template="$ants/Template_30"
prefix="$run/Output/ants"

export ANTSPATH="$ants_bin/"
export ANTSPATH1="$ants/Scripts/"
export PATH="$ants_bin:$PATH"
export ITK_GLOBAL_DEFAULT_NUMBER_OF_THREADS="$SLURM_CPUS_PER_TASK"

for step in 2 3; do
  bash "$ants/Scripts/antsCorticalThickness.sh" -y "$step" -d 3 -n 3 -w 0.25 \
    -a "$run/T1.nii.gz" -o "$prefix" \
    -e "$template/T_template0.nii.gz" \
    -t "$template/T_template0_BrainCerebellum.nii.gz" \
    -m "$template/T_template0_BrainCerebellumProbabilityMask.nii.gz" \
    -f "$template/T_template0_BrainCerebellumExtractionMask.nii.gz" \
    -p "$template/priors%d.nii.gz"
  test -s "${prefix}ACTStage${step}Complete.txt"
done

n4="${prefix}BrainSegmentation0N4.nii.gz"
seg="${prefix}BrainSegmentation.nii.gz"
mask="${prefix}BrainExtractionMask.nii.gz"
for file in "$n4" "$seg" "$mask"; do
  test -s "$file"
done

handoff="$run/abcd_inputs"
mkdir -p "$handoff"
"$ants_bin/ImageMath" 3 "$handoff/T1_brain.nii.gz" m "$n4" "$mask"
cp -- "$seg" "$handoff/T1_brain_seg.nii.gz"

export FSLDIR=/nas/longleaf/apps/fsl/5.0.10/fsl
source "$FSLDIR/etc/fslconf/fsl.sh"
export FSLOUTPUTTYPE=NIFTI_GZ
"$FSLDIR/bin/fslmaths" "$seg" -thr 3 -uthr 3 -bin "$handoff/T1_brain_wmseg.nii.gz"
"$FSLDIR/bin/fslstats" "$handoff/T1_brain_wmseg.nii.gz" -V |
  awk '{ if ($1 > 0) { print "White-matter voxels:", $1; ok=1 } } END { exit !ok }'
gzip -t -- "$handoff/"*.nii.gz
printf 'Anatomical handoff ready for QC: %s\n' "$handoff"
