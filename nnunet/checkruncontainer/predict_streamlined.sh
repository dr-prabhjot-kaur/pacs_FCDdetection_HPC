#!/bin/bash
#
# sbatch script for nnUNet inference on BCH HPC (GPU node) — STREAMLINED VERSION.
#
# Uses register_t1w_flair.py module for registration logic.
#
# Stage 2 (this job): register T1w/FLAIR, run nnunetv2_predict.
#
# Marker contract (written to $scratch):
#   .nnunet_done      nnUNet prediction succeeded
#   .nnunet_failed    nnUNet prediction failed
#
# Invoked as:
#   sbatch --job-name=nnunet-<study_key> predict_streamlined.sh <hpc_scratch_dir>

#SBATCH --job-name=nnunet-predict
#SBATCH --partition=gpu
#SBATCH --gres=gpu:1
#SBATCH --time=2:00:00
#SBATCH --mem=16G
#SBATCH --cpus-per-task=4
#SBATCH --output=/lab-share/Rad-Warfield-e2/Groups/Imp-Recons/prabhjot/work/gits/pacs_FCDdetection/data/slurm-logs/%j.out
#SBATCH --error=/lab-share/Rad-Warfield-e2/Groups/Imp-Recons/prabhjot/work/gits/pacs_FCDdetection/data/slurm-logs/%j.err

set -u

scratch="${1:?Usage: $0 <hpc_scratch_dir>}"
input_dir="$scratch/output/nnunet/Dataset003_FCD/imagesTs"
output_dir="$scratch/output/nnunet/Dataset003_FCD/predictions"
registered_dir="$scratch/output/nnunet/Dataset003_FCD/registered"
log_file="$scratch/job_nnunet.log"

mkdir -p "$output_dir" "$registered_dir"

exec > >(tee -a "$log_file") 2>&1

echo "========================================================"
echo "nnUNet inference (stage 2: predict + register)"
echo "  Scratch:    $scratch"
echo "  Input:      $input_dir"
echo "  Registered: $registered_dir"
echo "  Output:     $output_dir"
echo "  Job:        ${SLURM_JOB_ID:-N/A}"
echo "  Node:       $(hostname)"
echo "  GPU:        $(nvidia-smi --query-gpu=index,name --format=csv,noheader 2>/dev/null || echo 'N/A')"
echo "  Started:    $(date -u +%Y-%m-%dT%H-%M-%SZ)"
echo "========================================================"

# --- setup paths ---------------------------------------------------------

REPO_ROOT=/lab-share/Rad-Warfield-e2/Groups/Imp-Recons/prabhjot/work/gits/pacs_FCDdetection
REGISTER_SCRIPT="$REPO_ROOT/nnunet/register_t1w_flair.py"
NNUNET_SIF="${NNUNET_SIF:-$REPO_ROOT/containers/nnunet.sif}"
CONDA_ENV=/lab-share/Rad-Warfield-e2/Groups/Imp-Recons/prabhjot/work/gits/fcd4pacs/MAP/fcd_env
SINGULARITY_BIN="${SINGULARITY_BIN:-singularity}"

# --- validation ----------------------------------------------------------

for path in "$REGISTER_SCRIPT" "$NNUNET_SIF" "$CONDA_ENV/bin/python3"; do
    if [ ! -f "$path" ] && [ ! -x "$path" ]; then
        echo "!! Required file missing: $path"
        touch "$scratch/.nnunet_failed"
        exit 2
    fi
done

if [ ! -d "$input_dir" ]; then
    echo "!! Input directory missing: $input_dir"
    touch "$scratch/.nnunet_failed"
    exit 3
fi

n_nii=$(find "$input_dir" -maxdepth 1 -name "*.nii.gz" | wc -l)
if [ "$n_nii" -lt 1 ]; then
    echo "!! No .nii.gz files in $input_dir"
    touch "$scratch/.nnunet_failed"
    exit 4
fi

echo "Found $n_nii NIfTI file(s)"
ls -lh "$input_dir"/*.nii.gz

# --- python environment --------------------------------------------------

export PATH="$CONDA_ENV/bin:$PATH"
echo "Python: $(which python3) ($(python3 --version 2>&1))"

# --- check prerequisites -------------------------------------------------

echo
echo "Checking registration prerequisites..."
for cmd in fslreorient2std elastix transformix; do
    if command -v "$cmd" >/dev/null 2>&1; then
        echo "  ✓ $cmd"
    else
        echo "  ✗ $cmd (missing)"
        touch "$scratch/.nnunet_failed"
        exit 5
    fi
done

python3 -c "import SimpleITK" 2>/dev/null || {
    echo "  ✗ SimpleITK"
    touch "$scratch/.nnunet_failed"
    exit 6
}
echo "  ✓ SimpleITK"

# --- locate T1w and FLAIR ------------------------------------------------

T1W_RAW=$(find "$input_dir" -maxdepth 1 -name "*T1*" -o -name "*t1*" | grep -i ".nii.gz" | head -1)
FLAIR_RAW=$(find "$input_dir" -maxdepth 1 -name "*FLAIR*" -o -name "*flair*" | grep -i ".nii.gz" | head -1)

if [ -z "$T1W_RAW" ] || [ -z "$FLAIR_RAW" ]; then
    echo "!! Could not locate T1w/FLAIR in $input_dir"
    ls -lh "$input_dir"
    touch "$scratch/.nnunet_failed"
    exit 7
fi

echo
echo "Input images:"
echo "  T1w:   $T1W_RAW"
echo "  FLAIR: $FLAIR_RAW"

# --- reorient to RAS (fslreorient2std) -----------------------------------

echo
echo "=== Reorienting to RAS ==="

T1W_RAS="$registered_dir/T1w_ras.nii.gz"
FLAIR_RAS="$registered_dir/FLAIR_ras.nii.gz"

for img in "$T1W_RAW" "$FLAIR_RAW"; do
    base=$(basename "$img")
    out="$registered_dir/${base%.nii.gz}_ras.nii.gz"
    echo "  $base → $(basename "$out")"
    fslreorient2std "$img" "$out" || {
        echo "    !! fslreorient2std failed"
        touch "$scratch/.nnunet_failed"
        exit 8
    }
done

# --- register FLAIR to T1w (using Python module) -------------------------

echo
echo "=== Registering FLAIR → T1w ==="

python3 "$REGISTER_SCRIPT" \
    --t1w "$T1W_RAS" \
    --flair "$FLAIR_RAS" \
    --output-dir "$registered_dir" \
    --tfm-dir "$registered_dir/transforms"

rc=$?
if [ $rc -ne 0 ]; then
    echo "!! Registration failed (rc=$rc)"
    touch "$scratch/.nnunet_failed"
    exit 9
fi

# --- rename to nnunet convention -----

echo
echo "=== Renaming to nnUNet convention ==="

CASE_ID=$(basename "$T1W_RAW" | sed 's/_T1.*//' | sed 's/.nii.gz//')
if [ -z "$CASE_ID" ]; then
    CASE_ID="case"
fi

# Backup originals
for img in "$T1W_RAW" "$FLAIR_RAW"; do
    if [ -f "$img" ]; then
        mv "$img" "${img}.bak"
        echo "  Backed up: $(basename "$img").bak"
    fi
done

# Copy registered images to nnUNet format
NNUNET_T1W="$input_dir/${CASE_ID}_0000.nii.gz"
NNUNET_FLAIR="$input_dir/${CASE_ID}_0001.nii.gz"

cp "$registered_dir/T1w_registered.nii.gz" "$NNUNET_T1W"
cp "$registered_dir/FLAIR_registered.nii.gz" "$NNUNET_FLAIR"

echo "  $NNUNET_T1W"
echo "  $NNUNET_FLAIR"

# --- nnunet prediction ---------------------------------------------------

echo
echo "=== Running nnUNet prediction ==="
echo "  Container: $NNUNET_SIF"
echo "  Input:     $input_dir"
echo "  Output:    $output_dir"
echo

if ! command -v "$SINGULARITY_BIN" >/dev/null 2>&1; then
    if command -v module >/dev/null 2>&1; then
        module load singularity 2>/dev/null || true
    fi
fi

$SINGULARITY_BIN exec --nv "$NNUNET_SIF" \
    nnunetv2_predict \
    -i "$input_dir" \
    -o "$output_dir" \
    -d Dataset003_FCD \
    -c 3d_fullres \
    -f 0 \
    -tr nnUNetTrainer__nnUNetPlans__3d_fullres \
    --disable_tta

rc=$?

echo
echo "nnunetv2_predict: rc=$rc"

if [ $rc -ne 0 ]; then
    echo "!! Prediction failed"
    touch "$scratch/.nnunet_failed"
    exit $rc
fi

# --- success marker ------------------------------------------------------

if [ -d "$output_dir" ]; then
    pred_count=$(find "$output_dir" -name "*.nii.gz" 2>/dev/null | wc -l)
    echo "Output files: $pred_count"
    ls -lh "$output_dir"
fi

touch "$scratch/.nnunet_done"

echo
echo "========================================================"
echo "nnUNet inference succeeded."
echo "  Marker: $scratch/.nnunet_done"
echo "  Results: $output_dir"
echo "  Registered images: $registered_dir"
echo "========================================================"

exit 0
