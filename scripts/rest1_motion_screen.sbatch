#!/bin/bash
set -eo pipefail
umask 077

export FSLDIR=/nas/longleaf/apps/fsl/5.0.10/fsl
source "$FSLDIR/etc/fslconf/fsl.sh"
export PATH="$FSLDIR/bin:$PATH" FSLOUTPUTTYPE=NIFTI_GZ OMP_NUM_THREADS=1
set -u

run=$1
data=$2
mode=$3
line=1
if [[ "$mode" == screen ]]; then
  line=$((SLURM_ARRAY_TASK_ID + 1))
fi
IFS=$'\t' read -r index ap pa < <(sed -n "${line}p" "$run/pairs.tsv")
[[ -n "$index" && -n "$ap" && -n "$pa" ]]

tmp=$(mktemp -d "${SLURM_TMPDIR:-${TMPDIR:-/tmp}}/hcpd_fd_XXXXXX")
trap 'rm -rf -- "$tmp"' EXIT
cd "$tmp"

for direction in AP PA; do
  rel=$ap
  [[ "$direction" == AP ]] || rel=$pa
  bold="$data/$rel"
  [[ $(fslval "$bold" dim4 | awk '{print $1}') == 478 ]]
  fslval "$bold" pixdim4 |
    awk 'NR==1 && $1>0.799999 && $1<0.800001 {ok=1} END {exit !ok}'
  fslroi "$bold" "$direction.nii.gz" 8 470
done

calculate_fd() {
  local direction=$1 reference=$2 rel=$ap
  local -a opts=()
  [[ "$direction" == AP ]] || rel=$pa
  if [[ "$reference" == sbref ]]; then
    opts=(-reffile "$data/${rel%.nii.gz}_SBRef.nii.gz")
  fi
  mcflirt -in "$direction.nii.gz" -out "mc_${direction}_${reference}" \
    -plots "${opts[@]}"
  python3 - "mc_${direction}_${reference}.par" <<'PY'
import math
import sys

with open(sys.argv[1]) as stream:
    rows = [tuple(map(float, line.split())) for line in stream if line.strip()]
if len(rows) != 470 or any(
    len(row) != 6 or not all(map(math.isfinite, row)) for row in rows
):
    raise SystemExit("REVIEW: expected 470 rows of six finite motion parameters.")
fd = [
    sum(abs(x - y) * scale for x, y, scale in zip(a, b, (50, 50, 50, 1, 1, 1)))
    for a, b in zip(rows, rows[1:])
]
print(f"{math.fsum(fd) / len(fd):.10f}")
PY
}

if [[ "$mode" == replay ]]; then
  for reference in middle sbref; do
    ap_fd=$(calculate_fd AP "$reference")
    pa_fd=$(calculate_fd PA "$reference")
    printf 'Replay %s: AP=%s PA=%s\n' "$reference" "$ap_fd" "$pa_fd"
    if awk -v a="$ap_fd" -v p="$pa_fd" 'BEGIN {
      da=a-0.12606780; dp=p-0.11114770
      exit !(da>-0.00000005 && da<0.00000005 &&
             dp>-0.00000005 && dp<0.00000005)
    }'; then
      printf '%s\n' "$reference" > "$run/reference_mode.txt"
      echo 'PASS: both previous candidate 4 mean FD values reproduced.'
      exit 0
    fi
  done
  echo 'REVIEW: neither reference setting reproduced candidate 4.' >&2
  exit 1
fi

reference=$(cat "$run/reference_mode.txt")
[[ "$reference" == middle || "$reference" == sbref ]]
ap_fd=$(calculate_fd AP "$reference")
pa_fd=$(calculate_fd PA "$reference")
selected=$(awk -v a="$ap_fd" -v p="$pa_fd" \
  'BEGIN {print (a<p ? "AP" : (p<a ? "PA" : "TIE"))}')
printf '%s\t%s\t%s\t%s\n' "$index" "$ap_fd" "$pa_fd" "$selected" \
  > "$run/fd_${SLURM_ARRAY_TASK_ID}.tsv"
