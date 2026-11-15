#!/usr/bin/env bash
#SBATCH --partition=interact
#SBATCH --account=rc_htzhu_pi
#SBATCH --qos=normal
#SBATCH --job-name=hcpd_rest1_fix
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=1
#SBATCH --mem=16G
#SBATCH --time=03:00:00

set -eo pipefail
umask 077
ap="${HCPD_SDC_RUN:?Missing SDC pilot directory}"
ica="$ap/rest1_sdc.ica"
r_root=/nas/longleaf/rhel9/apps/r/4.5.0
fix_shared=/nas/longleaf/apps/fix/1.06/fix1.065
export FSLDIR=/nas/longleaf/apps/fsl/5.0.10/fsl
export BB_BIN_DIR=/work/users/t/e/tengfei/UKB_fMRI_pipeline/UK_biobank_pipeline_v_1-master
export templ="$BB_BIN_DIR/templates"
source "$FSLDIR/etc/fslconf/fsl.sh"
export PATH="$r_root/bin:$FSLDIR/bin:$PATH" FSLOUTPUTTYPE=NIFTI_GZ
unset R_HOME
if [[ -n ${1:-} ]]; then
  [[ -d "$1" ]] || { printf 'R package directory missing: %s\n' "$1" >&2; exit 1; }
  export R_LIBS_USER="$1"
fi
export OMP_NUM_THREADS=1 OPENBLAS_NUM_THREADS=1 MKL_NUM_THREADS=1

cd "$ica"
exec 9>"$ap/fix_resume.lock"
flock -n 9 || { echo 'Another FIX resume is running.' >&2; exit 1; }
motion="$ap/motion.par"
ncomponents=$(python3 - "$motion" filtered_func_data.ica/melodic_mix <<'PY_INPUT'
import math
import sys
from pathlib import Path

for i, filename in enumerate(sys.argv[1:]):
    rows = [line.split() for line in Path(filename).read_text().splitlines()
            if line.strip()]
    width = 6 if i == 0 else (len(rows[0]) if rows else 0)
    if not width or len(rows) != 470 or any(
        len(row) != width or not all(math.isfinite(float(x)) for x in row)
        for row in rows
    ):
        raise SystemExit(f"REVIEW: expected 470 × {width} finite values in {filename}")
    print(f"PASS: {filename}: 470 × {width}", file=sys.stderr)
print(width)
PY_INPUT
)

mkdir -p mc
motion_target=mc/prefiltered_func_data_mcf.par
if [[ -e "$motion_target" || -L "$motion_target" ]]; then
  cmp -s -- "$motion" "$motion_target" ||
    { echo 'REVIEW: existing FIX motion file differs from input motion.par' >&2; exit 1; }
else
  cp -- "$motion" "$motion_target"
fi

model="$fix_shared/training_files/UKBiobank.RData"
mask="$templ/MNI152_T1_2mm_brain_mask_bin.nii.gz"
for input in "$model" "$mask" mc/prefiltered_func_data_mcf.par filtered_func_data.nii.gz \
    filtered_func_data.ica/melodic_mix reg/standard.nii.gz \
    reg/example_func2standard_warp.nii.gz; do
  [[ -s "$input" ]] || { printf 'Missing input: %s\n' "$input" >&2; exit 1; }
done
tmp=$(mktemp -d "$ica/.fix_resume_${SLURM_JOB_ID:-local}_XXXXXX")
trap 'rm -rf -- "$tmp"' EXIT

export FSL_FIXDIR="$tmp/fix-r45/"
export FSL_FIX_R_CMD="$r_root/bin/R"
python3 - "$fix_shared" "$FSL_FIXDIR" "$r_root" <<'PY_FIX'
import os
from pathlib import Path
import shutil
import sys

shared, local, r_root = map(Path, sys.argv[1:])
old_r = b"/nas/longleaf/apps/r/3.3.1"
new_r = os.fsencode(r_root)
shared_prefix = os.fsencode(shared)
local_prefix = os.fsencode(local)
shutil.copytree(shared, local, symlinks=True, copy_function=os.symlink)

# Keep heavy FIX resources linked. Write private copies of the entry point,
# settings, and text launchers that contain the legacy R path.
for directory, _, files in os.walk(shared):
    for name in files:
        source = Path(directory) / name
        relative = source.relative_to(shared)
        if not source.is_file() or source.stat().st_size > 512 * 1024:
            continue
        if relative.parts[0] in {"compiled", "training_files"}:
            continue
        try:
            original = source.read_bytes()
        except PermissionError:
            if relative in {Path("fix"), Path("settings.sh")}:
                raise
            print(f"Skipping unreadable shared FIX file: {relative}")
            continue
        if b"\x00" in original:
            continue
        entry = relative in {Path("fix"), Path("settings.sh")}
        if not entry and old_r not in original and shared_prefix not in original:
            continue
        dest = local / relative
        dest.unlink()
        updated = original.replace(old_r, new_r).replace(shared_prefix, local_prefix)
        if relative == Path("settings.sh"):
            updated += b"\nexport FSL_FIX_R_CMD=" + new_r + b"/bin/R\n"
        dest.write_bytes(updated)
        shutil.copymode(source, dest)
        if original != updated:
            print(f"Local runtime update: {relative}")
PY_FIX
python3 - "$FSL_FIXDIR" <<'PY_MIX'
from pathlib import Path
import sys

root = Path(sys.argv[1])
for name, old, new in (
    ("fix_1a_extract_features.m", b"load(melodicMixFile)",
     b"load(melodicMixFile, '-ascii')"),
    ("fix_3_clean.m", b"load(sprintf('filtered_func_data.ica/melodic_mix'))",
     b"load(sprintf('filtered_func_data.ica/melodic_mix'), '-ascii')"),
):
    path = root / name
    data = path.read_bytes()
    if data.count(old) != 1:
        raise SystemExit(f"Unexpected FIX source for {name}")
    path.unlink()
    path.write_bytes(data.replace(old, new, 1))
    print(f"Updated private MATLAB reader: {name}")
PY_MIX
test -x "$FSL_FIXDIR/fix"
export PATH="$r_root/bin:$FSLDIR/bin:$FSL_FIXDIR:$PATH"
echo "FIX version: $(cat "$fix_shared/fixversion" 2>/dev/null || printf '1.065')"
"$r_root/bin/Rscript" --vanilla - "$model" <<'R_CHECK'
cat(R.version.string, "\n")
pkgs <- c("kernlab", "ROCR", "class", "party", "e1071", "randomForest")
ok <- vapply(pkgs, requireNamespace, logical(1), quietly = TRUE)
if (any(ok)) {
    versions <- vapply(pkgs[ok], function(p) as.character(packageVersion(p)), character(1))
    print(versions)
}
if (any(!ok)) cat("FIX package preflight, unavailable:", paste(pkgs[!ok], collapse = ", "), "\n")
stopifnot(all(ok),
          as.character(packageVersion("party")) == "1.0.25",
          as.character(packageVersion("coin")) == "1.2.2")
model <- new.env()
objects <- load(commandArgs(trailingOnly = TRUE)[[1]], envir = model)
stopifnot(length(objects) > 0)
cat("Original UKBiobank model loaded.\n")
R_CHECK

run_fix() {
  "$FSL_FIXDIR/fix" "$@"
}

label=fix4melview_UKBiobank_thr20.txt
for prior in fix "$label" filtered_func_data_clean.nii.gz; do
  if [[ -e "$prior" || -L "$prior" ]]; then
    printf 'Existing FIX output requires review: %s\n' "$prior" >&2
    exit 1
  fi
done

imcp "$HCPD_SDC_SEG" reg/highres_pveseg
invwarp --ref=reg/example_func --warp=reg/example_func2standard_warp \
  --out=reg/standard2example_func_warp

echo 'Extracting FIX features from the SDC MELODIC run'
if ! run_fix -f "$ica" || [[ ! -s fix/features.csv ]]; then
  if [[ -f fix/logMatlab.txt ]]; then tail -n 60 fix/logMatlab.txt >&2; fi
  exit 1
fi
awk -F, -v expected="$ncomponents" 'NF>1 {n++} END {print "FIX feature rows:",n+0; exit !(n==expected)}' fix/features.csv
if [[ ! -s "$label" ]]; then
  if [[ -f .fix_2b_predict.log ]]; then
    cp -n -- .fix_2b_predict.log "$ap/fix_predict_before_classification.log"
  fi
  printf 'FIX classification using existing features and %s\n' "$(command -v R)"
  if ! run_fix -c "$ica" "$model" 20 || [[ ! -s "$label" ]]; then
    echo 'FIX did not produce the expected UKBiobank threshold-20 labels.' >&2
    if [[ -f .fix_2b_predict.log ]]; then tail -n 60 .fix_2b_predict.log >&2; fi
    exit 1
  fi
fi
if ! awk 'NF {last=$0} END {exit !(last ~ /^[[:space:]]*\[[[:digit:],[:space:]]*\][[:space:]]*$/)}' "$label"; then
  echo "Invalid noise-component list in $label" >&2
  exit 1
fi

python3 - "$label" "$ncomponents" <<'PY_LABEL'
import ast
import sys
from pathlib import Path

lines = [line.strip() for line in Path(sys.argv[1]).read_text().splitlines()
         if line.strip()]
noise = ast.literal_eval(lines[-1])
ncomponents = int(sys.argv[2])
if (not isinstance(noise, list)
    or any(type(i) is not int or not 1 <= i <= ncomponents for i in noise)
    or len(noise) != len(set(noise))):
    raise SystemExit("REVIEW: invalid FIX component IDs.")
print(f"FIX labels: {len(noise)} noise components, {ncomponents - len(noise)} retained.")
PY_LABEL

clean=filtered_func_data_clean.nii.gz
if [[ ! -s "$clean" ]]; then
  echo 'FIX cleanup with the original motion and high-pass options'
  if ! run_fix -a "$ica/$label" -m -h 100; then
    if [[ -f .fix.log ]]; then tail -n 60 .fix.log >&2; fi
    [[ -s "$clean" ]] || exit 1
    echo 'FIX cleanup returned nonzero. Checking the output it wrote.'
  fi
fi
test -s "$clean"
gzip -t -- "$clean"
npre=$(fslval filtered_func_data.nii.gz dim4 | awk '{print $1}')
nclean=$(fslval "$clean" dim4 | awk '{print $1}')
nraw=$(fslval "$HCPD_SDC_BOLD" dim4 | awk '{print $1}')
npts=$(awk '$1=="set" && $2=="fmri(npts)" {print $3}' design.fsf)
ndelete=$(awk '$1=="set" && $2=="fmri(ndelete)" {print $3}' design.fsf)
nmel=$(awk 'NF {n++} END {print n+0}' filtered_func_data.ica/melodic_mix)

printf 'Frames: raw=%s, design=%s, deleted=%s, FEAT=%s, MELODIC=%s, FIX=%s\n' \
  "$nraw" "$npts" "$ndelete" "$npre" "$nmel" "$nclean"

if [[ ! "$nraw" =~ ^[1-9][0-9]*$ || ! "$ndelete" =~ ^(0|[1-9][0-9]*)$ ]] ||
   [[ "$npts" != "$nraw" || "$npre" != "$nmel" || "$npre" != "$nclean" ]] ||
   (( ndelete >= nraw )) ||
   [[ "$npre" != "$((nraw - ndelete))" ]]; then
  echo 'Frame counts are inconsistent with the FEAT design.' >&2
  exit 1
fi

echo 'Apply the existing standard-space warp and UKB brain mask'
applywarp --ref=reg/standard --in="$clean" --out="$tmp/std.nii.gz" \
  --warp=reg/example_func2standard_warp --interp=spline
fslmaths "$tmp/std.nii.gz" -mas "$mask" "$tmp/$clean"
fslmaths "$tmp/$clean" -Tstd -bin "$tmp/filtered_func_data_clean_stdmask.nii.gz"
test -s "$tmp/filtered_func_data_clean_stdmask.nii.gz"
gzip -t -- "$tmp/$clean" "$tmp/filtered_func_data_clean_stdmask.nii.gz"
nstd=$(fslval "$tmp/$clean" dim4 | awk '{print $1}')
[[ "$nstd" == "$npre" && "$nstd" == 470 ]]
for image in "$clean" "$tmp/$clean"; do
  tr=$(fslval "$image" pixdim4 | awk '{print $1}')
  awk -v tr="$tr" 'BEGIN {exit !(tr>0.7999 && tr<0.8001)}'
done
mkdir -p reg_standard
mv -f -- "$tmp/filtered_func_data_clean_stdmask.nii.gz" reg_standard/
mv -f -- "$tmp/$clean" reg_standard/
printf 'FIX output: %s/reg_standard/%s | volumes=%s\n' "$ica" "$clean" "$nstd"
