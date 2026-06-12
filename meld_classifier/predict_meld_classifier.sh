#!/bin/bash
#
# CPU/GPU sbatch wrapper for MELD *classifier* prediction.
#
# Unlike meld_graph (which runs inside a .sif), the classifier .sif could not
# be built, so this runs NATIVELY in a conda env. Same per-study staging idea
# as meld_graph/predict.sh, different runtime (conda instead of singularity).
#
# Dispatched after organizeinputs.py succeeds (T1/FLAIR already chosen + in
# the MELD layout). Assumes site H52 features are ALREADY harmonized, so the
# pipeline only needs to run the classifier stages (no feature extraction).
#
# Deployed to:
#   HPC: .../pacs_FCDdetection/meld_classifier/predict_meld_classifier.sh
#
# Usage:
#   sbatch meld_classifier/predict_meld_classifier.sh <hpc_scratch_dir>
#
# Markers (consumed by submitter.py — see NOTE at bottom about adding these):
#   .meld_classifier_done    on success
#   .meld_classifier_failed  on failure

#SBATCH --job-name=meld-classifier-predict
#SBATCH --partition=bch-compute            # <-- change to bch-gpu + add --gres=gpu:1 if the classifier needs GPU
#SBATCH --time=8:00:00
#SBATCH --mem=32G
#SBATCH --cpus-per-task=4
#SBATCH --output=/lab-share/Rad-Warfield-e2/Groups/Imp-Recons/prabhjot/work/gits/pacs_FCDdetection/data/slurm-logs/meld_classifier_%j.out
#SBATCH --error=/lab-share/Rad-Warfield-e2/Groups/Imp-Recons/prabhjot/work/gits/pacs_FCDdetection/data/slurm-logs/meld_classifier_%j.err

set -u

scratch=$1

# ======================================================================
# CONFIG — VERIFY THESE THREE BLOCKS BEFORE FIRST RUN
# ======================================================================

# --- (1) conda env + pipeline entrypoint (NO sif) ---------------------
CLS_ROOT=/lab-share/Rad-Warfield-e2/Groups/Imp-Recons/prabhjot/work/gits/meldFromRainbow/meld_classifier
CONDA_ENV="$CLS_ROOT/condaenve3Meld"
PIPELINE="$CLS_ROOT/scripts/new_patient_pipeline/new_pt_pipeline.py"

# --- (2) where the classifier's reference data lives (source-of-truth) -
#     models       <- copied into per-study  models/
#     meld_params  <- copied into per-study  meld_params/
#     preproc      <- copied into per-study  output/preprocessed_surf_data/
DATAPATH1="$CLS_ROOT/datapath1"
SRC_MODELS="$DATAPATH1"                       # <-- CONFIRM: is it datapath1/  or  datapath1/models/ ?
SRC_MELD_PARAMS="$DATAPATH1/meld_params"
SRC_PREPROC="$DATAPATH1/output/preprocessed_surf_data"

# --- (3) site + licenses ----------------------------------------------
SITE_CODE="${SITE_CODE:-H52}"
FS_LICENSE="${FS_LICENSE:-/lab-share/Rad-Warfield-e2/Groups/Imp-Recons/prabhjot/work/gits/MELDgraph2026/meld_graph/license.txt}"
MELD_LICENSE="${MELD_LICENSE:-/lab-share/Rad-Warfield-e2/Groups/Imp-Recons/prabhjot/work/gits/MELDgraph2026/meld_graph/meld_license.txt}"

# ======================================================================

# Per-study paths. This dir becomes MELD_DATA_PATH (the classifier's root).
study_dir="$scratch/output/meld_classifier"
input_dir="$study_dir/input"
output_dir="$study_dir/output"
log_file="$scratch/meld_classifier_job.log"

mkdir -p "$output_dir"

exec > >(tee -a "$log_file") 2>&1

echo "========================================================"
echo "MELD classifier inference job (conda-native, no sif)"
echo "  Scratch:    $scratch"
echo "  Study root: $study_dir   (= MELD_DATA_PATH)"
echo "  Conda env:  $CONDA_ENV"
echo "  Pipeline:   $PIPELINE"
echo "  Slurm job:  ${SLURM_JOB_ID:-N/A}"
echo "  Node:       $(hostname)"
echo "  Started:    $(date -u +%Y-%m-%dT%H-%M-%SZ)"
echo "  Site code:  $SITE_CODE"
echo "========================================================"

# --- Pre-flight: conda env + pipeline ---------------------------------

if [ ! -x "$CONDA_ENV/bin/python" ]; then
    echo "!! No python at $CONDA_ENV/bin/python"
    touch "$scratch/.meld_classifier_failed"
    exit 2
fi
if [ ! -f "$PIPELINE" ]; then
    echo "!! Pipeline script not found: $PIPELINE"
    touch "$scratch/.meld_classifier_failed"
    exit 3
fi

# Use the env's python directly (mirrors how organizeinputs.py is run).
export PATH="$CONDA_ENV/bin:$PATH"
PY="$CONDA_ENV/bin/python"
echo "Python: $("$PY" --version 2>&1) ($PY)"

# --- Pre-flight: organizeinputs MELD layout exists --------------------
# organizeinputs.py writes the MELD layout under the meld_graph tree:
#   <scratch>/output/meld/input/MELD_<SITE>_3T_FCD_<subj>/T1/T1.nii.gz
#                                                        /FLAIR/FLAIR.nii.gz
#                                                        /demographic_features.csv
# We reuse that same per-subject layout for the classifier.
MELD_GRAPH_INPUT="$scratch/output/meld/input"
if [ ! -d "$MELD_GRAPH_INPUT" ]; then
    echo "!! Expected MELD layout from organizeinputs not found: $MELD_GRAPH_INPUT"
    touch "$scratch/.meld_classifier_failed"
    exit 4
fi

subjects=( $(ls -1 "$MELD_GRAPH_INPUT" 2>/dev/null | grep "^MELD_${SITE_CODE}_") )
if [ ${#subjects[@]} -eq 0 ]; then
    echo "!! No MELD_${SITE_CODE}_* subject dir in $MELD_GRAPH_INPUT"
    ls "$MELD_GRAPH_INPUT" 2>/dev/null
    touch "$scratch/.meld_classifier_failed"
    exit 5
fi
echo "Subjects found:"
printf '    %s\n' "${subjects[@]}"

# --- Compose the per-study classifier data tree -----------------------
echo
echo "Composing per-study classifier data tree under: $study_dir"

mkdir -p "$input_dir" "$output_dir" "$study_dir/models" "$study_dir/meld_params"
mkdir -p "$output_dir/preprocessed_surf_data"

# (a) input/  <- copy each subject's T1 + FLAIR (+ demographic) from the
#     meld_graph layout into the classifier input layout.
for subj in "${subjects[@]}"; do
    src="$MELD_GRAPH_INPUT/$subj"
    dst="$input_dir/$subj"
    mkdir -p "$dst/T1" "$dst/FLAIR"
    cp -p "$src/T1/T1.nii.gz"       "$dst/T1/T1.nii.gz"       2>/dev/null \
        && echo "  ✓ $subj T1"    || echo "  ✗ $subj T1 MISSING"
    cp -p "$src/FLAIR/FLAIR.nii.gz" "$dst/FLAIR/FLAIR.nii.gz" 2>/dev/null \
        && echo "  ✓ $subj FLAIR" || echo "  ✗ $subj FLAIR MISSING"
    if [ -f "$src/demographic_features.csv" ]; then
        cp -p "$src/demographic_features.csv" "$dst/demographic_features.csv"
    fi
done

# (b) models/        <- from datapath1
echo "Copying models from: $SRC_MODELS"
cp -rp "$SRC_MODELS"/* "$study_dir/models/" 2>/dev/null \
    || { echo "!! models copy failed from $SRC_MODELS"; touch "$scratch/.meld_classifier_failed"; exit 6; }

# (c) meld_params/   <- from datapath1/meld_params
echo "Copying meld_params from: $SRC_MELD_PARAMS"
cp -rp "$SRC_MELD_PARAMS"/* "$study_dir/meld_params/" 2>/dev/null \
    || { echo "!! meld_params copy failed from $SRC_MELD_PARAMS"; touch "$scratch/.meld_classifier_failed"; exit 7; }

# (d) output/preprocessed_surf_data/  <- preharmonized H52 features
echo "Copying preprocessed_surf_data (preharmonized features) from: $SRC_PREPROC"
cp -rp "$SRC_PREPROC"/* "$output_dir/preprocessed_surf_data/" 2>/dev/null \
    || { echo "!! preprocessed_surf_data copy failed from $SRC_PREPROC"; touch "$scratch/.meld_classifier_failed"; exit 8; }

# (e) licenses (some classifier builds want a FreeSurfer license present)
cp -f "$FS_LICENSE"   "$study_dir/license.txt"      2>/dev/null || true
cp -f "$MELD_LICENSE" "$study_dir/meld_license.txt" 2>/dev/null || true

echo
echo "Per-study tree state:"
echo "  input/ subjects:            $(ls -1 "$input_dir" 2>/dev/null | wc -l)"
echo "  models/ entries:            $(ls -1 "$study_dir/models" 2>/dev/null | wc -l)"
echo "  meld_params/ entries:       $(ls -1 "$study_dir/meld_params" 2>/dev/null | wc -l)"
echo "  preprocessed_surf_data/:    $(ls -1 "$output_dir/preprocessed_surf_data" 2>/dev/null | wc -l)"

# --- Subject list + demographic list ----------------------------------
ids_file="$study_dir/list_of_subjects.txt"
ls -1 "$input_dir" | grep "^MELD_${SITE_CODE}_" > "$ids_file"
echo
echo "list_of_subjects.txt:"
cat "$ids_file" | sed 's/^/    /'

# --- Tell the classifier where its data root is -----------------------
# Classic meld_classifier reads MELD_DATA_PATH (or a meld_config.ini). We set
# the env var to the per-study root. If your build uses meld_config.ini
# instead, write that here pointing data_path -> $study_dir.
export MELD_DATA_PATH="$study_dir"
echo "MELD_DATA_PATH=$MELD_DATA_PATH"

# --- Run the classifier pipeline --------------------------------------
echo
echo "============================================================"
echo "Running MELD classifier pipeline..."
echo "  Started: $(date -u +%Y-%m-%dT%H-%M-%SZ)"
echo "============================================================"

# >>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>
# VERIFY THIS INVOCATION against:  python "$PIPELINE" --help
#
# Because H52 features are ALREADY harmonized/preprocessed, you want to SKIP
# segmentation + feature extraction and run only prediction. The classic MELD
# classifier flags for that are some subset of:
#     -ids   <list_of_subjects.txt>      (or  -id <single_subject>)
#     -site  <SITE_CODE>   /   -harmo_code <SITE_CODE>
#     --skip_segmentation
#     --skip_feature_extraction
#     --no_nifti           (skip nifti prep if features exist)
#     --no_report          (drop if you DO want the pdf report)
# Adjust the exact flag names/values to match YOUR new_pt_pipeline.py.
# >>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>

"$PY" "$PIPELINE" \
    -ids "$ids_file" \
    -harmo_code "$SITE_CODE" \
    --skip_segmentation \
    --skip_feature_extraction
rc=$?

echo
echo "Finished: $(date -u +%Y-%m-%dT%H-%M-%SZ), rc=$rc"

# --- Verify outputs ----------------------------------------------------
echo
echo "Outputs produced:"
echo "  predictions_reports: $(ls -d "$output_dir"/predictions_reports/*/ 2>/dev/null | wc -l)"

n_predicted=0
for s in "${subjects[@]}"; do
    if [ -d "$output_dir/predictions_reports/$s" ] || \
       ls "$output_dir"/predictions_reports/*"$s"* >/dev/null 2>&1; then
        n_predicted=$((n_predicted + 1))
        echo "  ✓ predicted: $s"
    else
        echo "  ✗ NOT PREDICTED: $s"
    fi
done

# --- Mark completion ---------------------------------------------------
if [ $rc -eq 0 ] && [ "$n_predicted" -ge 1 ]; then
    touch "$scratch/.meld_classifier_done"
    echo "Touched $scratch/.meld_classifier_done"
    exit 0
else
    touch "$scratch/.meld_classifier_failed"
    echo "Touched $scratch/.meld_classifier_failed (rc=$rc, predicted=$n_predicted)"
    exit ${rc:-1}
fi

# ======================================================================
# INTEGRATION NOTES (do these to wire it into the pipeline):
#
# 1. submitter.py — add .meld_classifier_done/.meld_classifier_failed to
#    _classify_completion the same way we added nnunet (best-effort settle),
#    so the scratch dir isn't archived before this job finishes.
#
# 2. process_series.sh — dispatch this job. Note dispatch_downstream() checks
#    for a .sif and will mark-failed if none is given. Either:
#      (a) add a no-sif dispatch branch, or
#      (b) call sbatch directly for this one:
#          sbatch --job-name="meld-classifier-$study_key" \
#                 --export="ALL,SITE_CODE=$SITE_CODE" \
#                 "$REPO_ROOT/meld_classifier/predict_meld_classifier.sh" \
#                 "$scratch"
# ======================================================================
