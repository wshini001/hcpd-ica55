#!/bin/bash
set -euo pipefail
umask 077
run=$1
topup=$2
data=$3
IFS=$'\t' read -r index direction relative < \
  <(sed -n "${SLURM_ARRAY_TASK_ID}p" "$run/tasks.tsv")
case "$direction" in
  AP) slot=01 ;;
  PA) slot=02 ;;
  *) exit 1 ;;
esac
bold="$data/$relative"
sbref="${bold%.nii.gz}_SBRef.nii.gz"
out="$run/results/$index"
mkdir -p "$run/results"
mkdir "$out"

printf 'Index=%s direction=%s TOPUP slot=%s\n' "$index" "$direction" "$slot"
bash "${HCPD_SCRIPTS:?}/rest1_full_bold.sh" "$out" "$bold" "$sbref" "$topup/results/$index" "$slot"
