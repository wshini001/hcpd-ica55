#!/usr/bin/env bash
set -euo pipefail
umask 077
batch=$1
source_dir="$2/$SLURM_ARRAY_TASK_ID"
ants=$3
ants_bin=$4
dest="$batch/results/$SLURM_ARRAY_TASK_ID"
files=(T1_brain.nii.gz T1_brain_seg.nii.gz T1_brain_wmseg.nii.gz)

if [[ -d "$dest" ]]; then
  for name in "${files[@]}"; do test -s "$dest/abcd_inputs/$name"; done
  printf 'Existing results: %s\n' "$dest"
  exit 0
fi

qc=$5
if ! awk -F '\t' -v id="$SLURM_ARRAY_TASK_ID" '
  NR > 1 && $1 == id { rows++; if ($2 == "NUMERIC_PASS") passes++ }
  END { exit !(rows == 1 && passes == 1) }
' "$qc/stage1_qc.tsv"; then
  printf 'REVIEW: stage 1 numeric QC did not pass for row %s.\n' "$SLURM_ARRAY_TASK_ID" >&2
  exit 42
fi

work=$(mktemp -d "${SLURM_TMPDIR:-${TMPDIR:-/tmp}}/hcpd_seg_${SLURM_ARRAY_TASK_ID}.XXXXXX")
publish=
trap 'rm -rf -- "$work"; if [[ -n "$publish" ]]; then rm -rf -- "$publish"; fi' EXIT
cp -- "$source_dir/T1.nii.gz" "$work/"
cp -RL -- "$source_dir/Output" "$work/"
cd "$work"
bash "${HCPD_SCRIPTS:?}/ants_stage23_driver.sh" "$work" "$ants" "$ants_bin"
for name in "${files[@]}"; do
  test -s "$work/abcd_inputs/$name"
  gzip -t -- "$work/abcd_inputs/$name"
done
publish=$(mktemp -d "$batch/results/.row_${SLURM_ARRAY_TASK_ID}.XXXXXX")
mkdir "$publish/abcd_inputs"
for name in "${files[@]}"; do
  cp -- "$work/abcd_inputs/$name" "$publish/abcd_inputs/"
done
mv -T -- "$publish" "$dest"
publish=
printf 'Stage 2–3 output ready: %s\n' "$dest"
