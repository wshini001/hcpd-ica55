# HCP-D REST1 ICA55 workflow

This workflow produces UK Biobank–aligned ICA55 connectivity features from one REST1 scan per HCP-D V1 visit. One selected AP scan and one selected PA scan completed all processing through ICA55 and passed voxelwise time-series QC on Longleaf. The current pilot implementation uses scans with 478 input volumes at TR 0.8 s and retains 470 volumes after initial trimming.

## Processing steps

| Step | Inputs and method | Outputs |
| --- | --- | --- |
| 1. T1–fMRI matching and T1 preprocessing | Match T1 and REST1 AP/PA by visit. Reuse the ANTs N4 bias-corrected, skull-stripped T1 and tissue segmentation. | Same-visit anatomical inputs |
| 2. Motion screening | Discard the first eight volumes of each REST1 run. Estimate motion with MCFLIRT using the default middle-volume reference. Average Power FD over the 469 adjacent-volume differences, using a 50 mm rotation radius. Select the lower-mean-FD run. | AP FD, PA FD and selected direction |
| 3. Motion and susceptibility distortion correction | Use a verified same-visit AP/PA spin-echo EPI pair with TOPUP. Verify phase encoding, total readout time and field map association or acquisition provenance. Align the selected SBRef to its same-direction spin-echo image. Apply per-volume motion and distortion in one resampling with Jacobian intensity correction. | Corrected BOLD, corrected SBRef, motion parameters and visual QC |
| 4. Functional preprocessing and denoising | Run FEAT and MELODIC with repeated trimming, motion correction and susceptibility correction disabled. Supply the selected scan's motion parameters to FIX and apply the FEAT standard-space warp to the denoised output. | Native and 2 mm MNI denoised BOLD |
| 5. ICA55 extraction | Run demeaned spatial regression using UKB group d100 maps and the FSL MNI 2 mm brain mask. Retain the reference 55 components and compute FSLNets connectivity. | Time series, node amplitudes and ordered connectivity edges |

## Reference code checked on Longleaf

Paths below identify the references inspected for this implementation.

| Step | Reference | Verified correspondence |
| --- | --- | --- |
| 1 | `/hickory/users/y/u/yuqic/from_work/ANTS_script/ANTs_longleaf.m` | ANTs processing reference. The HCP-D handoff applies the brain extraction mask to the N4-corrected T1 and exports tissue segmentation. |
| 4 | `/overflow/tengfei/ABCD_fixICA/step2_preprocess.py` and the UKB pipeline's `bb_functional_pipeline/bb_prepare_rfMRI1` and `bb_functional_pipeline/bb_fix1` | Uses the original `UKBiobank.RData 20 -m -h 100` settings. HCP-D supplies externally estimated motion parameters and runs feature extraction, classification and cleanup separately. The Longleaf runner uses a private FIX runtime with R compatibility and explicit MATLAB text loading for `melodic_mix`. Spline standard-space interpolation and UKB brain masking follow the reference. |
| 5 | `/work/users/t/e/tengfei/BCP_rest/step2_preprocess.py` and `step3_cor.m`, plus UKB `bb_functional_pipeline/bb_netmats.m` and `bb_IDP/scripts/bb_IDP_func_ICA_netmats.m` | Matches the d100 component selection, FSLNets time-series cleanup, full-correlation setting `-19.7177`, ridge partial-correlation setting `-18.8310` with ridge parameter `0.5`, upper-triangle edge order and standard-deviation amplitudes. HCP-D uses TR 0.8 s, the FIX-cleaned standard-space input, and TSV outputs with explicit UKB component IDs. The ABCD example's d100 regression line is commented out. |

UKB reference root on Longleaf: `/work/users/t/e/tengfei/UKB_fMRI_pipeline/UK_biobank_pipeline_v_1-master`.

## Validation of the two pilot scans

| Metric | AP pilot | PA pilot |
| --- | ---: | ---: |
| Volumes after FIX and MNI conversion | 470 | 470 |
| Median DVARS before → after FIX | 374.09 → 329.18 | 361.24 → 292.53 |
| 95th percentile DVARS before → after FIX | 475.94 → 342.23 | 381.25 → 301.27 |
| Newly flat native-mask voxels | 0 | 0 |
| MNI-mask voxels with temporal variation | 99.81% | 99.81% |

The same native-space voxels and display scale were used for each before/after comparison. The AP pilot had visible motion peaks, with attenuated DVARS spikes after FIX. Both scans produced 470 × 55 time series, 55 amplitudes and 1,485 edges per connectivity measure. The PA workflow reproduced the AP spatial-regression reference with zero observed difference and matched all AP component IDs and edge positions.

## Running on Longleaf

See [RUNBOOK](docs/RUNBOOK.md) for staged commands, required inputs and source provenance. The assembled launchers need a Longleaf replay before release.
