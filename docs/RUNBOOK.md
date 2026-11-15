# Run the HCP-D REST1 ICA55 workflow on Longleaf

Use Bash, Python 3 on the compute nodes, Slurm, FSL 5.0.10, ANTs and its Template_30 resources, MATLAB R2024b, FIX 1.065 and R 4.5.0 with the tested FIX libraries (including party 1.0-25 and coin 1.2-2). Set paths to the installed UK Biobank resources. Keep inputs, job logs and derivative images on Longleaf. All paths supplied to jobs should be absolute. This revision targets the pilot acquisition with 478 raw frames, eight initial frames removed and TR 0.8 s.

From the repository root on Longleaf:

```bash
export HCPD_SCRIPTS="$PWD/scripts"
export HCPD_ICA55_UKB=/work/users/t/e/tengfei/UKB_fMRI_pipeline/UK_biobank_pipeline_v_1-master
slurm=(--partition=interact --account=rc_htzhu_pi --qos=normal --ntasks=1)
```

Use quoted shell variables for the local paths in the following steps.

1. **Anatomy.** The existing batch outputs can be reused. For new anatomy, the stage 1 script takes the raw T1 image, ANTs resource directory, ANTs binary directory and a fresh output directory. The stage 2–3 array takes the batch root, stage 1 results root, ANTs resource directory, ANTs binary directory and QC directory. Create the batch root's `results` directory. Match the array index to the stage 1 results directory. The QC directory must contain the existing `stage1_qc.tsv` with its header and a `NUMERIC_PASS` row per selected index. The stage 2–3 driver is included.
2. **Motion screening.** Use `rest1_motion_screen.sbatch SCREEN DATA replay` and then `rest1_motion_screen.sbatch SCREEN DATA screen`. The first line of `SCREEN/pairs.tsv` is the original candidate 4 replay pair, with columns `replay<TAB>ap_relative_path<TAB>pa_relative_path`. Later lines have the same three columns with an index in column one. Use one array task per later row, starting at 1. If using the reference mode already established by successful replay, reuse its `reference_mode.txt` containing `middle`. Retain only the lower-FD direction for a visit. Review any ties and field map associations.
3. **TOPUP and full BOLD.** Each fresh TOPUP or full-BOLD run directory requires a headerless `tasks.tsv` with `index<TAB>direction<TAB>selected_BOLD_relative_path`. For full BOLD, include the rows whose TOPUP SBRef plots passed review. Array indices are 1-based line numbers. Inspect SBRef plots and then the corrected mean BOLD and T1 alignment.

   ```bash
   sbatch "${slurm[@]}" --array="1-$n_topup" --cpus-per-task=1 --mem=8G --time=01:30:00 \
     "$HCPD_SCRIPTS/rest1_topup_array.sbatch" "$topup" "$data"
   sbatch "${slurm[@]}" --array="1-$n_full" --cpus-per-task=1 --mem=12G --time=04:00:00 \
     "$HCPD_SCRIPTS/rest1_full_bold_array.sbatch" "$full" "$topup" "$data"
   ```

4. **FEAT and FIX.** Supply a fresh existing FEAT directory, the corrected BOLD, motion, corrected SBRef, same-visit ANTs `abcd_inputs` directory and the locally saved AP SDC `design.fsf` template. Verify the same-visit association before launching. Verify completion of all FEAT child jobs, their registration QC, and the expected FEAT/MELODIC outputs before submitting FIX. FEAT can place child jobs in the default partition.

   ```bash
   sbatch "${slurm[@]}" --cpus-per-task=1 --mem=16G --time=07:00:00 \
     "$HCPD_SCRIPTS/rest1_feat.sbatch" "$feat_run" \
     "$full/results/$index/bold_sdc.nii.gz" "$full/results/$index/motion.par" \
     "$topup/results/$index/sbref_after_jac.nii.gz" "$anatomy" "$ap_fsf"

   export HCPD_SDC_RUN="$feat_run"
   export HCPD_SDC_SEG="$anatomy/T1_brain_seg.nii.gz"
   export HCPD_SDC_BOLD="$full/results/$index/bold_sdc.nii.gz"
   # Set R_LIBS_USER to the tested legacy party/coin and base FIX package directories.
   sbatch "$HCPD_SCRIPTS/rest1_fix.sbatch"
   ```

5. **ICA55.** Create a fresh ICA55 output directory. Verify 470 × 55 time series, 55 amplitudes and 1,485 ordered rows with both connectivity measures. Compare the component and edge identifier columns against the existing AP pilot during replay.

   ```bash
   sbatch "${slurm[@]}" --cpus-per-task=1 --mem=16G --time=03:00:00 \
     "$HCPD_SCRIPTS/rest1_ica55.sbatch" \
     "$feat_run/rest1_sdc.ica/reg_standard/filtered_func_data_clean.nii.gz" "$ica55_out"
   ```

The voxelwise QC script uses `HCPD_QC_AP_ICA` and `HCPD_QC_PA_ICA` as absolute MELODIC directory inputs. Source the FSL environment and put FSL on PATH before invoking MATLAB. Run from a separate QC output directory. Review FD, DVARS, carpet plots and MNI coverage alongside registration QC.

## Source and validation record

- Anatomy, motion-screening and TOPUP code came from saved Longleaf scripts.
- The shared motion and distortion correction runner was adapted from the saved Longleaf implementation for both phase-encoding directions.
- The shared FEAT launcher was adapted from the completed PA FEAT workflow. Key settings match the submitted and executed AP designs. Historical AP launcher 9044154 failed its immediate output check while child jobs 9044156–9044159 subsequently completed.
- The shared FIX launcher adapts the saved PA and AP runs. It checks the measured number of MELODIC components in the mixing matrix instead of using a pilot-specific count.
- The ICA55 launcher uses the map, mask and regression options that exactly reproduced the AP spatial-regression output in PA job 9150264. The MATLAB extraction code is unchanged.
- The QC script came from successful job 9190472, with pilot paths replaced by environment variables. The assembled launchers have been syntax-checked. A new end-to-end Longleaf replay of this assembled version is pending.
