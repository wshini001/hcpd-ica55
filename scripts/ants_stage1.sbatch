#!/usr/bin/env bash
#SBATCH --job-name=hcpd_ants1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=3
#SBATCH --mem=24000M
#SBATCH --time=23:59:59
set -euo pipefail
umask 077

source_t1=$1
ants=$2
ants_bin=$3
run=$4
template="$ants/Template_30"

export ANTSPATH="$ants_bin/"
export ANTSPATH1="$ants/Scripts/"
export PATH="$ants_bin:$PATH"
export ITK_GLOBAL_DEFAULT_NUMBER_OF_THREADS="$SLURM_CPUS_PER_TASK"

mkdir -p "$run/Output"
cp -- "$source_t1" "$run/T1_0.nii.gz"
"$ants_bin/ResampleImageBySpacing" 3 \
  "$run/T1_0.nii.gz" "$run/T1.nii.gz" 1 1 1 0 0 1

bash "$ants/Scripts/antsCorticalThickness.sh" -y 1 -d 3 -n 3 -w 0.25 \
  -a "$run/T1.nii.gz" \
  -o "$run/Output/ants" \
  -e "$template/T_template0.nii.gz" \
  -t "$template/T_template0_BrainCerebellum.nii.gz" \
  -m "$template/T_template0_BrainCerebellumProbabilityMask.nii.gz" \
  -f "$template/T_template0_BrainCerebellumExtractionMask.nii.gz" \
  -p "$template/priors%d.nii.gz"

mask="$run/Output/antsBrainExtractionMask.nii.gz"
test -s "$mask"
gzip -t "$mask"
printf 'Stage 1 mask written: %s\n' "$mask"
ls -lh "$run/Output"
