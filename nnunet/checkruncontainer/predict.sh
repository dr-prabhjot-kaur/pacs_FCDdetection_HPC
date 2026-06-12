#!/bin/bash
#
# sbatch script for nnUNet inference on BCH HPC (GPU node).
#
# Stage 2 (this job): register T1w/FLAIR, run nnunetv2_predict.
#
# Marker contract (written to $scratch):
#   .nnunet_done      nnUNet prediction succeeded
#   .nnunet_failed    nnUNet prediction failed (see job.log and prediction logs)
#
# Invoked as:
#   sbatch --job-name=nnunet-<study_key> predict.sh <hpc_scratch_dir>
#
# Expected inputs:
#   $scratch/output/nnunet/Dataset003_FCD/imagesTs/
#     Contains T1w.nii.gz, FLAIR.nii.gz (unregistered, possibly misaligned)
#
# Output:
#   $scratch/output/nnunet/Dataset003_FCD/predictions/
#     Contains nnUNet model predictions (segmentation masks, etc.)
#
#   $scratch/output/nnunet/Dataset003_FCD/registered/
#     Contains T1w_registered.nii.gz, FLAIR_registered.nii.gz (aligned, same space)

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
echo "nnUNet inference job (stage 2: predict)"
echo "  Scratch:        $scratch"
echo "  Input:          $input_dir"
echo "  Registered:     $registered_dir"
echo "  Output:         $output_dir"
echo "  Slurm job:      ${SLURM_JOB_ID:-N/A}"
echo "  Job name:       ${SLURM_JOB_NAME:-N/A}"
echo "  Node:           $(hostname)"
echo "  GPU:            $(nvidia-smi --query-gpu=index,name --format=csv,noheader 2>/dev/null || echo 'N/A')"
echo "  Started:        $(date -u +%Y-%m-%dT%H-%M-%SZ)"
echo "========================================================"

# --- validation ----------------------------------------------------------

if [ ! -d "$input_dir" ]; then
    echo "!! Input directory missing: $input_dir"
    touch "$scratch/.nnunet_failed"
    exit 2
fi

# Count available NIfTI files
n_nii=$(find "$input_dir" -maxdepth 1 -name "*.nii.gz" | wc -l)
if [ "$n_nii" -lt 1 ]; then
    echo "!! No .nii.gz files in $input_dir"
    touch "$scratch/.nnunet_failed"
    exit 3
fi
echo "Found $n_nii NIfTI file(s) in input directory"
ls -lh "$input_dir"/*.nii.gz 2>/dev/null || true

# --- locate nnunet.sif ---------------------------------------------------

NNUNET_SIF="${NNUNET_SIF:-/lab-share/Rad-Warfield-e2/Groups/Imp-Recons/prabhjot/work/gits/pacs_FCDdetection/containers/nnunet.sif}"

if [ ! -f "$NNUNET_SIF" ]; then
    echo "!! nnunet.sif not found: $NNUNET_SIF"
    touch "$scratch/.nnunet_failed"
    exit 4
fi

SINGULARITY_BIN="${SINGULARITY_BIN:-singularity}"
if ! command -v "$SINGULARITY_BIN" >/dev/null 2>&1; then
    if command -v module >/dev/null 2>&1; then
        module load singularity 2>/dev/null || true
    fi
fi
if ! command -v "$SINGULARITY_BIN" >/dev/null 2>&1; then
    echo "!! singularity not on PATH"
    touch "$scratch/.nnunet_failed"
    exit 5
fi

echo "Using nnunet.sif: $NNUNET_SIF"
echo "Using singularity: $SINGULARITY_BIN"

# --- install registration deps in temp conda env (host-side) -----

# We'll run registration on the host (not in container) using SimpleITK + elastix.
# First, ensure fsl-reorient2std + SimpleITK + elastix are available.

CONDA_ENV=/lab-share/Rad-Warfield-e2/Groups/Imp-Recons/prabhjot/work/gits/fcd4pacs/MAP/fcd_env

if [ ! -x "$CONDA_ENV/bin/python3" ]; then
    echo "!! No python3 at $CONDA_ENV/bin/python3"
    touch "$scratch/.nnunet_failed"
    exit 6
fi

export PATH="$CONDA_ENV/bin:$PATH"
echo "Python: $(which python3) ($(python3 --version 2>&1))"

# Check for required tools/packages
check_cmd() {
    local cmd="$1"
    if command -v "$cmd" >/dev/null 2>&1; then
        echo "  ✓ $cmd"
        return 0
    else
        echo "  ✗ $cmd (missing)"
        return 1
    fi
}

echo
echo "Checking registration prerequisites..."
check_cmd "fslreorient2std" || {
    echo "    Install: conda install -c conda-forge fsl-core"
    touch "$scratch/.nnunet_failed"
    exit 7
}

python3 -c "import SimpleITK; print('  ✓ SimpleITK')" 2>/dev/null || {
    echo "  ✗ SimpleITK (missing)"
    echo "    Install: pip install SimpleITK"
    touch "$scratch/.nnunet_failed"
    exit 8
}

check_cmd "elastix" || {
    echo "    Install: conda install -c conda-forge elastix"
    touch "$scratch/.nnunet_failed"
    exit 9
}
check_cmd "transformix" || {
    echo "    (elastix package should include transformix)"
    touch "$scratch/.nnunet_failed"
    exit 10
}

echo

# --- helper functions for registration ----------------------------------

# Reorient a NIfTI to RAS using fsl's fslreorient2std
reorient_to_ras() {
    local input="$1"
    local output="$2"
    
    echo "  Reorienting: $input → $output"
    fslreorient2std "$input" "$output" || {
        echo "    !! fslreorient2std failed"
        return 1
    }
    return 0
}

# Register FLAIR to T1w using SimpleITK + elastix
# Fixed: T1w, Moving: FLAIR
# Outputs: registered FLAIR, transform file
register_flair_to_t1w() {
    local t1w="$1"        # fixed
    local flair="$2"      # moving
    local out_flair="$3"  # output registered FLAIR
    local tfm_dir="$4"    # directory for transform files
    
    python3 << 'PYREG'
import sys
import SimpleITK as sitk
import os

t1w_file = sys.argv[1]
flair_file = sys.argv[2]
out_file = sys.argv[3]
tfm_dir = sys.argv[4]

print(f"Reading T1w (fixed): {t1w_file}")
fixed = sitk.ReadImage(t1w_file, sitk.sitkFloat32)
print(f"  Shape: {fixed.GetSize()}, Spacing: {fixed.GetSpacing()}")

print(f"Reading FLAIR (moving): {flair_file}")
moving = sitk.ReadImage(flair_file, sitk.sitkFloat32)
print(f"  Shape: {moving.GetSize()}, Spacing: {moving.GetSpacing()}")

os.makedirs(tfm_dir, exist_ok=True)

# Use elastix parameter maps for multiresolution B-spline registration
# (affine + deformable).
elastix_params = [
    sitk.GetDefaultParameterMap('affine'),
    sitk.GetDefaultParameterMap('bspline'),
]

print("Running elastix registration (affine + B-spline)...")
elastix = sitk.ElastixImageFilter()
elastix.SetFixedImage(fixed)
elastix.SetMovingImage(moving)
for i, params in enumerate(elastix_params):
    elastix.AddParameterMap(params)
elastix.SetOutputDirectory(tfm_dir)
elastix.LogToFileOn()
elastix.Execute()

# Get the registered (warped) moving image
registered_flair = elastix.GetResultImage()

# Save registered FLAIR
print(f"Writing registered FLAIR: {out_file}")
sitk.WriteImage(registered_flair, out_file)
print(f"  Shape: {registered_flair.GetSize()}, Spacing: {registered_flair.GetSpacing()}")

print("Registration complete. Transform maps saved to:", tfm_dir)
PYREG
    
    python3 "$t1w" "$flair" "$out_flair" "$tfm_dir" || {
        echo "    !! SimpleITK registration failed"
        return 1
    }
    return 0
}

# Resample one image to match another's grid (same spacing, origin, direction)
resample_to_ref() {
    local ref_file="$1"      # reference image (fixed/target)
    local mov_file="$2"      # image to resample
    local out_file="$3"      # output resampled
    
    python3 << 'PYRESAMPLE'
import sys
import SimpleITK as sitk

ref_file = sys.argv[1]
mov_file = sys.argv[2]
out_file = sys.argv[3]

print(f"Reading reference: {ref_file}")
ref = sitk.ReadImage(ref_file, sitk.sitkFloat32)
print(f"  Shape: {ref.GetSize()}, Spacing: {ref.GetSpacing()}")

print(f"Reading image to resample: {mov_file}")
mov = sitk.ReadImage(mov_file, sitk.sitkFloat32)
print(f"  Shape (before): {mov.GetSize()}, Spacing: {mov.GetSpacing()}")

# Resample moving to match reference grid
resampler = sitk.ResampleImageFilter()
resampler.SetReferenceImage(ref)
resampler.SetInterpolator(sitk.sitkLinear)
resampled = resampler.Execute(mov)

print(f"  Shape (after): {resampled.GetSize()}, Spacing: {resampled.GetSpacing()}")

print(f"Writing resampled: {out_file}")
sitk.WriteImage(resampled, out_file)

print("Resampling complete.")
PYRESAMPLE
    
    python3 "$ref_file" "$mov_file" "$out_file" || {
        echo "    !! Resampling failed"
        return 1
    }
    return 0
}

# --- registration pipeline -----------------------------------------------

echo
echo "========== REGISTRATION PIPELINE =========="
echo

# Locate T1w and FLAIR in input directory
T1W_RAW=$(find "$input_dir" -maxdepth 1 -name "*T1*" -name "*.nii.gz" | head -1)
FLAIR_RAW=$(find "$input_dir" -maxdepth 1 -name "*FLAIR*" -name "*.nii.gz" | head -1)

if [ -z "$T1W_RAW" ] || [ -z "$FLAIR_RAW" ]; then
    echo "!! Could not locate T1w and FLAIR in $input_dir"
    echo "   T1w: $T1W_RAW"
    echo "   FLAIR: $FLAIR_RAW"
    touch "$scratch/.nnunet_failed"
    exit 11
fi

echo "Found input images:"
echo "  T1w:   $T1W_RAW"
echo "  FLAIR: $FLAIR_RAW"
echo

# Step 1: Reorient to RAS
T1W_RAS="$registered_dir/T1w_ras.nii.gz"
FLAIR_RAS="$registered_dir/FLAIR_ras.nii.gz"

echo "Step 1: Reorient to RAS"
reorient_to_ras "$T1W_RAW" "$T1W_RAS" || {
    echo "!! Reorientation failed"
    touch "$scratch/.nnunet_failed"
    exit 12
}
reorient_to_ras "$FLAIR_RAW" "$FLAIR_RAS" || {
    echo "!! Reorientation failed"
    touch "$scratch/.nnunet_failed"
    exit 13
}
echo

# Step 2: Register FLAIR to T1w (elastix)
TFM_DIR="$registered_dir/transforms"
FLAIR_REGISTERED="$registered_dir/FLAIR_registered_pre_resample.nii.gz"

echo "Step 2: Register FLAIR (moving) to T1w (fixed) using elastix"
register_flair_to_t1w "$T1W_RAS" "$FLAIR_RAS" "$FLAIR_REGISTERED" "$TFM_DIR" || {
    echo "!! Registration failed"
    touch "$scratch/.nnunet_failed"
    exit 14
}
echo

# Step 3: Resample both T1w and registered FLAIR to common grid
# (T1w is already the fixed image; we resample the registered FLAIR to T1w's exact grid)
T1W_FINAL="$registered_dir/T1w_registered.nii.gz"
FLAIR_FINAL="$registered_dir/FLAIR_registered.nii.gz"

echo "Step 3: Resample to common grid (T1w reference)"
cp "$T1W_RAS" "$T1W_FINAL"
echo "  Copied T1w: $T1W_FINAL"

resample_to_ref "$T1W_RAS" "$FLAIR_REGISTERED" "$FLAIR_FINAL" || {
    echo "!! Resampling failed"
    touch "$scratch/.nnunet_failed"
    exit 15
}
echo

# --- rename to nnunet convention -----

echo "Step 4: Rename to nnUNet convention (_0000 for T1w, _0001 for FLAIR)"

# Infer case ID from original filenames
CASE_ID=$(basename "$T1W_RAW" | sed 's/_T1.*//' | sed 's/.nii.gz//')
if [ -z "$CASE_ID" ]; then
    CASE_ID="case"
fi

NNUNET_T1W="$input_dir/${CASE_ID}_0000.nii.gz"
NNUNET_FLAIR="$input_dir/${CASE_ID}_0001.nii.gz"

# Back up originals (in case we want to inspect them later)
if [ -f "$T1W_RAW" ]; then
    mv "$T1W_RAW" "${T1W_RAW}.bak"
fi
if [ -f "$FLAIR_RAW" ]; then
    mv "$FLAIR_RAW" "${FLAIR_RAW}.bak"
fi

# Copy registered images to nnUNet convention
cp "$T1W_FINAL" "$NNUNET_T1W"
cp "$FLAIR_FINAL" "$NNUNET_FLAIR"

echo "  $NNUNET_T1W"
echo "  $NNUNET_FLAIR"
echo

ls -lh "$input_dir"/*.nii.gz
echo

# --- nnunet prediction ---------------------------------------------------

echo "========== NNUNET PREDICTION =========="
echo

# nnUNet expects:
#   INPUT: Dataset003_FCD/imagesTs/<case>_0000.nii.gz, <case>_0001.nii.gz, ...
#   OUTPUT: Dataset003_FCD/predictions/<case>.nii.gz (or segmentation output)

# The container has nnunet_models baked in (/opt/nnunet_models)
# and environment vars set for nnUNet_results, nnUNet_raw, etc.

echo "Running nnunetv2_predict via singularity..."
echo "  Container: $NNUNET_SIF"
echo "  Input dir: $input_dir"
echo "  Output dir: $output_dir"
echo

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
echo "nnunetv2_predict finished: rc=$rc"
echo

if [ $rc -ne 0 ]; then
    echo "!! nnUNet prediction failed (rc=$rc)"
    touch "$scratch/.nnunet_failed"
    exit $rc
fi

# --- success marker ------------------------------------------------------

echo "Checking output directory for predictions..."
if [ -d "$output_dir" ]; then
    pred_count=$(find "$output_dir" -name "*.nii.gz" | wc -l)
    echo "  Found $pred_count output file(s)"
    ls -lh "$output_dir"/*.nii.gz 2>/dev/null || true
fi

touch "$scratch/.nnunet_done"
echo
echo "========================================================"
echo "nnUNet inference completed successfully."
echo "  Touched: $scratch/.nnunet_done"
echo "  Results: $output_dir"
echo "  Registered images: $registered_dir"
echo "========================================================"
echo "Finished: $(date -u +%Y-%m-%dT%H-%M-%SZ)"

exit 0
