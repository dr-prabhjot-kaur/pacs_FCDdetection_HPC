#!/bin/bash
# run_meld_classifier.sh — stage the MELD-classifier data root inside a study's
# scratch dir and run the new-patient pipeline (segmentation -> preprocessing ->
# prediction). Builds at:  <scratch>/output/meld_classifier   (sibling of output/meld).
#
# Reads raw T1/FLAIR from the meld_graph layout that organizeinputs.py already wrote:
#   <scratch>/output/meld/input/<subject>/T1/T1.nii.gz
#                                         /FLAIR/FLAIR.nii.gz
#
# Usage:
#   bash run_meld_classifier.sh <scratch_dir> [subject_id]
# Example:
#   bash run_meld_classifier.sh /lab-share/.../scratch/4022088_20100330_1ac8fcef
# (subject auto-detected from the meld layout; pass one explicitly to override.)

set -u

# ============================ CONFIG — verify before first run ============================
MELD_INSTALL="/lab-share/Rad-Warfield-e2/Groups/Imp-Recons/prabhjot/work/gits/meldFromRainbow/meld_classifier"
# The meld_classifier PACKAGE (paths.py, meld_cohort.py, ...) is NOT in $MELD_INSTALL —
# only scripts/ + setup.py are. The matching package lives in a sibling repo. We symlink
# it into $MELD_INSTALL/meld_classifier so `import meld_classifier` resolves.
# ScriptsBackup pairs with this scripts/ (2 local edits). If preprocessing later errors
# reading H52 combat/features, switch to .../meld_classifier_diffScanners/meld_classifier.
MELD_PKG_SRC="/lab-share/Rad-Warfield-e2/Groups/Imp-Recons/prabhjot/work/gits/meldFromRainbow/meld_classifierScriptsBackup/meld_classifier"
CONDA_ENV="$MELD_INSTALL/condaenve3Meld"
DATAPATH1="$MELD_INSTALL/datapath1"          # source-of-truth reference (models, meld_params, combat)
PIPELINE="scripts/new_patient_pipeline/new_pt_pipeline.py"   # run relative to $MELD_INSTALL
SITE_CODE="H52"
FREESURFER_HOME="${FREESURFER_HOME:-/programs/x86_64-linux/freesurfer/7.1.1}"   # <=7.2 required
# =========================================================================================

SCRATCH="${1:?need scratch dir, e.g. /lab-share/.../scratch/4022088_20100330_1ac8fcef}"
SCRATCH="${SCRATCH%/}"
# any nonzero exit (preflight or pipeline) writes the failure marker so the submitter
# doesn't wait forever. Success path writes .meld_classifier_done explicitly and exits 0.
trap '[ $? -ne 0 ] && [ -d "$SCRATCH" ] && touch "$SCRATCH/.meld_classifier_failed"' EXIT

# per-study log (lands in scratch so it travels back when the submitter pulls results).
# Under sbatch this is in addition to the Slurm meld_classifier_%j.out/.err files.
log_file="$SCRATCH/meld_classifier_job.log"
[ -d "$SCRATCH" ] && exec > >(tee -a "$log_file") 2>&1
MELD_INPUT="$SCRATCH/output/meld/input"      # where organizeinputs.py put T1/FLAIR
DATA_ROOT="$SCRATCH/output/meld_classifier"  # the classifier's per-study root (built here)

# subject: explicit arg, else auto-detect the MELD_<SITE>_* dir in the meld layout
if [ "${2:-}" != "" ]; then
    SUBJECT_ID="$2"
else
    SUBJECT_ID="$(ls -1 "$MELD_INPUT" 2>/dev/null | grep "^MELD_${SITE_CODE}_" | head -1)"
fi

echo "=========================================================="
echo "MELD classifier — new patient run"
echo "  scratch:     $SCRATCH"
echo "  subject:     ${SUBJECT_ID:-<none found>}"
echo "  site:        $SITE_CODE"
echo "  data root:   $DATA_ROOT"
echo "  install:     $MELD_INSTALL"
echo "  freesurfer:  $FREESURFER_HOME"
echo "=========================================================="

# --- preflight ---------------------------------------------------------------------------
[ -n "$SUBJECT_ID" ]          || { echo "!! no MELD_${SITE_CODE}_* subject in $MELD_INPUT"; ls "$MELD_INPUT" 2>/dev/null; exit 2; }
[ -d "$DATAPATH1" ]           || { echo "!! reference datapath1 missing: $DATAPATH1"; exit 2; }
[ -x "$CONDA_ENV/bin/python" ] || { echo "!! no python at $CONDA_ENV/bin/python"; exit 2; }
[ -f "$MELD_INSTALL/$PIPELINE" ] || { echo "!! pipeline missing: $MELD_INSTALL/$PIPELINE"; exit 2; }
[ -d "$FREESURFER_HOME" ]     || { echo "!! FREESURFER_HOME not found: $FREESURFER_HOME"; exit 2; }

# ensure the meld_classifier package is importable from $MELD_INSTALL (symlink it in once)
if [ ! -e "$MELD_INSTALL/meld_classifier/__init__.py" ]; then
    [ -f "$MELD_PKG_SRC/__init__.py" ] || { echo "!! package source missing: $MELD_PKG_SRC"; exit 2; }
    ln -sfn "$MELD_PKG_SRC" "$MELD_INSTALL/meld_classifier"
    echo "  linked package: $MELD_INSTALL/meld_classifier -> $MELD_PKG_SRC"
fi

T1_SRC="$MELD_INPUT/$SUBJECT_ID/T1/T1.nii.gz"
FLAIR_SRC="$MELD_INPUT/$SUBJECT_ID/FLAIR/FLAIR.nii.gz"
[ -f "$T1_SRC" ]    || { echo "!! T1 not found: $T1_SRC"; exit 2; }
[ -f "$FLAIR_SRC" ] || { echo "!! FLAIR not found: $FLAIR_SRC"; exit 2; }

if [ "$(awk -F_ '{print NF}' <<<"$SUBJECT_ID")" -ne 5 ]; then
    echo "!! subject_id must be MELD_<site>_<scanner>_<group>_<id> (5 fields): $SUBJECT_ID"; exit 2
fi

# H52 combat params MUST already exist, else the pipeline recomputes combat from this one
# patient and corrupts harmonisation. Abort loudly if absent.
COMBAT="$DATAPATH1/output/preprocessed_surf_data/MELD_${SITE_CODE}/${SITE_CODE}_combat_parameters.hdf5"
[ -f "$COMBAT" ] || { echo "!! H52 combat params not found: $COMBAT"; echo "   Refusing to run (would corrupt harmonisation)."; exit 3; }

# --- STEP 1: build per-study data root at <scratch>/output/meld_classifier ---------------
# Layout the pipeline expects (paths.py / meld_config.ini):
#   input/<subj>/T1/*T1*.nii*      input/<subj>/FLAIR/*FLAIR*.nii*
#   models/                        (experiment_path)        <- symlink (read-only ref)
#   meld_params/                   (meld_params_path)       <- symlink (read-only ref)
#   output/preprocessed_surf_data/ (base_path, has combat)  <- COPY (writable; new subj written here)
#   output/fs_outputs/             (fs_subjects_path)       <- created (recon-all writes here)
#   demographics_file.csv, list_subjects.txt
echo; echo "[1/2] Staging data root..."
rm -rf "$DATA_ROOT"
mkdir -p "$DATA_ROOT/input/$SUBJECT_ID/T1" \
         "$DATA_ROOT/input/$SUBJECT_ID/FLAIR" \
         "$DATA_ROOT/output/fs_outputs"

cp -p "$T1_SRC"    "$DATA_ROOT/input/$SUBJECT_ID/T1/T1.nii.gz"
cp -p "$FLAIR_SRC" "$DATA_ROOT/input/$SUBJECT_ID/FLAIR/FLAIR.nii.gz"

ln -s "$DATAPATH1/models"      "$DATA_ROOT/models"
ln -s "$DATAPATH1/meld_params" "$DATA_ROOT/meld_params"
cp -rp "$DATAPATH1/output/preprocessed_surf_data" "$DATA_ROOT/output/preprocessed_surf_data"

cp -p "$DATAPATH1/demographics_file.csv" "$DATA_ROOT/demographics_file.csv" 2>/dev/null \
    || echo "  (no demographics_file.csv to copy — ok, combat exists so it's unused)"
echo "$SUBJECT_ID" > "$DATA_ROOT/list_subjects.txt"

cat > "$MELD_INSTALL/meld_config.ini" <<EOF
[DEFAULT]
meld_data_path = $DATA_ROOT

[develop]
base_path = %(meld_data_path)s/output/preprocessed_surf_data
experiment_path = %(meld_data_path)s/models
fs_subjects_path = %(meld_data_path)s/output/fs_outputs
meld_params_path = %(meld_data_path)s/meld_params
EOF
echo "  meld_config.ini -> meld_data_path = $DATA_ROOT"

echo "  staged:"
echo "    input/$SUBJECT_ID/{T1,FLAIR}     : $(ls "$DATA_ROOT/input/$SUBJECT_ID/T1" "$DATA_ROOT/input/$SUBJECT_ID/FLAIR" 2>/dev/null | grep -c nii)"
echo "    models -> $(readlink "$DATA_ROOT/models")"
echo "    meld_params -> $(readlink "$DATA_ROOT/meld_params")"
echo "    output/preprocessed_surf_data    : $(ls -1 "$DATA_ROOT/output/preprocessed_surf_data" 2>/dev/null | wc -l) entries"

# --- STEP 2: source FreeSurfer + conda, run pipeline -------------------------------------
echo; echo "[2/2] Running pipeline..."
# SetUpFreeSurfer.sh isn't `set -u`-clean (refs $SUBJECTS_DIR before defining it).
set +u
export FREESURFER_HOME
export SUBJECTS_DIR="$DATA_ROOT/output/fs_outputs"
source "$FREESURFER_HOME/SetUpFreeSurfer.sh"
echo "  FreeSurfer: $(recon-all --version 2>/dev/null | head -1)"

export PATH="$CONDA_ENV/bin:$PATH"
# repo root on PYTHONPATH: pipeline does `from scripts...` (namespace pkg, no __init__.py).
export PYTHONPATH="$MELD_INSTALL${PYTHONPATH:+:$PYTHONPATH}"
PY="$CONDA_ENV/bin/python"
echo "  Python: $("$PY" --version 2>&1)"

cd "$MELD_INSTALL" || exit 4
# -ids resolved relative to meld_data_path -> bare filename. -demos omitted on purpose
# (combat exists; omitting avoids the recompute-from-one-patient footgun).
set -x
"$PY" "$PIPELINE" -site "$SITE_CODE" -ids list_subjects.txt
rc=$?
set +x

# --- verify -------------------------------------------------------------------------------
echo; echo "Pipeline rc=$rc"
PRED_DIR="$DATA_ROOT/output/predictions_reports/$SUBJECT_ID"
if [ $rc -eq 0 ] && [ -d "$PRED_DIR" ]; then
    echo "✓ prediction outputs: $PRED_DIR"
    ls -R "$PRED_DIR" 2>/dev/null | head -40
    touch "$SCRATCH/.meld_classifier_done"
    echo "Touched $SCRATCH/.meld_classifier_done"
    exit 0
else
    echo "✗ no prediction output at $PRED_DIR (rc=$rc)"
    echo "  check: $DATA_ROOT/output/fs_outputs/$SUBJECT_ID/scripts/recon-all.log"
    exit ${rc:-1}   # trap writes .meld_classifier_failed
fi
