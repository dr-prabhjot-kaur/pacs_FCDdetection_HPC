#!/bin/bash
#
# Standalone test harness for predict_container.sh
# Run independently of process_series.sh
#
# Usage:
#   bash test_predict_standalone.sh [--t1w /path/to/T1w.nii.gz] [--flair /path/to/FLAIR.nii.gz]
#
# If no images provided, creates synthetic test data.

set -e

# Configuration
REPO_ROOT="${REPO_ROOT:-/lab-share/Rad-Warfield-e2/Groups/Imp-Recons/prabhjot/work/gits/pacs_FCDdetection}"
PREDICT_SCRIPT="$REPO_ROOT/nnunet/predict_container.sh"
NNUNET_SIF="${NNUNET_SIF:-$REPO_ROOT/containers/nnunet.sif}"

# Test parameters
T1W_INPUT=""
FLAIR_INPUT=""
KEEP_SCRATCH=false

# Parse arguments
while [ $# -gt 0 ]; do
    case "$1" in
        --t1w)
            T1W_INPUT="$2"
            shift 2
            ;;
        --flair)
            FLAIR_INPUT="$2"
            shift 2
            ;;
        --keep)
            KEEP_SCRATCH=true
            shift
            ;;
        --help)
            cat <<EOF
Standalone test harness for predict_container.sh

Usage:
  $0 [options]

Options:
  --t1w FILE          Path to T1w NIfTI file (optional; creates synthetic if omitted)
  --flair FILE        Path to FLAIR NIfTI file (optional; creates synthetic if omitted)
  --keep              Keep scratch directory after test (for debugging)
  --help              Show this message

Examples:
  # With your own images
  $0 --t1w /data/my_T1w.nii.gz --flair /data/my_FLAIR.nii.gz

  # With synthetic test data
  $0

  # Keep scratch for inspection
  $0 --keep

EOF
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

# Create scratch directory
scratch=$(mktemp -d /tmp/nnunet_test_XXXXX)
echo "========================================================"
echo "nnUNet Stage 2 Standalone Test"
echo "========================================================"
echo "Scratch dir: $scratch"
echo "REPO_ROOT:   $REPO_ROOT"
echo "Script:      $PREDICT_SCRIPT"
echo "Container:   $NNUNET_SIF"
echo

# Validate prerequisites
echo "Checking prerequisites..."

if [ ! -f "$PREDICT_SCRIPT" ]; then
    echo "!! predict_container.sh not found: $PREDICT_SCRIPT"
    echo "   Did you copy it to nnunet/ directory?"
    exit 1
fi
echo "  ✓ predict_container.sh"

if [ ! -f "$NNUNET_SIF" ]; then
    echo "!! nnunet.sif not found: $NNUNET_SIF"
    echo "   Check container path in REPO_ROOT"
    exit 1
fi
echo "  ✓ nnunet.sif"

if ! command -v singularity >/dev/null 2>&1; then
    if command -v module >/dev/null 2>&1; then
        echo "  Loading singularity module..."
        module load singularity 2>/dev/null || true
    fi
fi
if ! command -v singularity >/dev/null 2>&1; then
    echo "!! singularity not on PATH"
    exit 1
fi
echo "  ✓ singularity"

# Create input directory structure
echo
echo "Creating directory structure..."
input_dir="$scratch/output/nnunet/Dataset003_FCD/imagesTs"
mkdir -p "$input_dir"
echo "  Created: $input_dir"

# Prepare test images
echo
echo "Preparing test images..."

if [ -n "$T1W_INPUT" ] && [ -f "$T1W_INPUT" ]; then
    # Use provided T1w
    echo "  Using provided T1w: $T1W_INPUT"
    cp "$T1W_INPUT" "$input_dir/T1w.nii.gz"
else
    # Create synthetic T1w
    echo "  Creating synthetic T1w..."
    python3 << 'PYSYN'
import nibabel as nib
import numpy as np
from pathlib import Path

# Create 3D image (192×256×256 voxels, typical brain MRI)
shape = (192, 256, 256)
data = np.random.randn(*shape).astype(np.float32) * 50 + 100

# Add some structure (sphere in center to look brain-like)
center = np.array(shape) // 2
radius = 60
y, x, z = np.ogrid[-center[0]:shape[0]-center[0],
                     -center[1]:shape[1]-center[1],
                     -center[2]:shape[2]-center[2]]
mask = x*x + y*y + z*z <= radius*radius
data[mask] = np.random.randn(*shape)[mask] * 20 + 150

# Create affine (1×1×1 mm voxels, centered at origin)
affine = np.eye(4)
affine[:3, :3] *= 1.0  # 1 mm isotropic
affine[:3, 3] = -np.array(shape) / 2

# Create NIfTI image and save
img = nib.Nifti1Image(data, affine)
output = Path("T1w.nii.gz")
nib.save(img, output)
print(f"Created synthetic T1w: {output} ({shape})")
PYSYN

    if [ -f "T1w.nii.gz" ]; then
        mv T1w.nii.gz "$input_dir/"
    else
        echo "!! Failed to create synthetic T1w"
        exit 1
    fi
fi

if [ -n "$FLAIR_INPUT" ] && [ -f "$FLAIR_INPUT" ]; then
    # Use provided FLAIR
    echo "  Using provided FLAIR: $FLAIR_INPUT"
    cp "$FLAIR_INPUT" "$input_dir/FLAIR.nii.gz"
else
    # Create synthetic FLAIR (same geometry as T1w)
    echo "  Creating synthetic FLAIR..."
    python3 << 'PYSYN'
import nibabel as nib
import numpy as np
from pathlib import Path

# Load T1w to match its geometry
t1w_img = nib.load("T1w.nii.gz")
shape = t1w_img.shape
affine = t1w_img.affine

# Create different tissue contrast for FLAIR
data = np.random.randn(*shape).astype(np.float32) * 40 + 120

# Add lesion-like structure (bright spot)
center = np.array(shape) // 2
lesion_center = center + np.array([30, 20, 10])
lesion_radius = 15
y, x, z = np.ogrid[-lesion_center[0]:shape[0]-lesion_center[0],
                     -lesion_center[1]:shape[1]-lesion_center[1],
                     -lesion_center[2]:shape[2]-lesion_center[2]]
lesion_mask = x*x + y*y + z*z <= lesion_radius*lesion_radius
data[lesion_mask] = 200

# Create NIfTI image and save
img = nib.Nifti1Image(data, affine)
output = Path("FLAIR.nii.gz")
nib.save(img, output)
print(f"Created synthetic FLAIR: {output} ({shape}, matching T1w geometry)")
PYSYN

    if [ -f "FLAIR.nii.gz" ]; then
        mv FLAIR.nii.gz "$input_dir/"
    else
        echo "!! Failed to create synthetic FLAIR"
        exit 1
    fi
fi

echo "Test images ready:"
ls -lh "$input_dir"/*.nii.gz

# --- Run predict_container.sh ---

echo
echo "========================================================"
echo "RUNNING predict_container.sh"
echo "========================================================"
echo

bash "$PREDICT_SCRIPT" "$scratch"
rc=$?

echo
echo "========================================================"
echo "TEST RESULTS"
echo "========================================================"
echo "Return code: $rc"
echo

# Check for success marker
if [ -f "$scratch/.nnunet_done" ]; then
    echo "✓ SUCCESS MARKER FOUND: .nnunet_done"
else
    echo "✗ No .nnunet_done marker"
fi

# Check for failure marker
if [ -f "$scratch/.nnunet_failed" ]; then
    echo "✗ FAILURE MARKER FOUND: .nnunet_failed"
fi

# Check outputs
echo
echo "Output directories:"
echo

if [ -d "$scratch/output/nnunet/Dataset003_FCD/registered" ]; then
    echo "✓ Registered images:"
    ls -lh "$scratch/output/nnunet/Dataset003_FCD/registered/" | grep -E "\.nii\.gz|\.json" | head -10
else
    echo "✗ No registered/ directory"
fi

echo

if [ -d "$scratch/output/nnunet/Dataset003_FCD/predictions" ]; then
    pred_count=$(find "$scratch/output/nnunet/Dataset003_FCD/predictions" -name "*.nii.gz" 2>/dev/null | wc -l)
    if [ "$pred_count" -gt 0 ]; then
        echo "✓ Predictions ($pred_count file(s)):"
        ls -lh "$scratch/output/nnunet/Dataset003_FCD/predictions"/*.nii.gz
    else
        echo "✗ No prediction .nii.gz files in predictions/"
    fi
else
    echo "✗ No predictions/ directory"
fi

# Show logs
echo
echo "========================================================"
echo "LOGS"
echo "========================================================"
echo

if [ -f "$scratch/job_nnunet.log" ]; then
    echo "Last 50 lines of job_nnunet.log:"
    echo
    tail -50 "$scratch/job_nnunet.log"
else
    echo "!! No job_nnunet.log found"
fi

# Summary
echo
echo "========================================================"
echo "CLEANUP"
echo "========================================================"

if [ "$KEEP_SCRATCH" = true ]; then
    echo "Keeping scratch directory: $scratch"
    echo "  View registered:  $scratch/output/nnunet/Dataset003_FCD/registered/"
    echo "  View predictions: $scratch/output/nnunet/Dataset003_FCD/predictions/"
    echo "  View logs:        $scratch/job_nnunet.log"
else
    echo "Removing scratch directory..."
    rm -rf "$scratch"
    echo "Done."
fi

echo

# Exit with test result
if [ $rc -eq 0 ] && [ -f "$scratch/.nnunet_done" ]; then
    echo "✓✓✓ TEST PASSED ✓✓✓"
    exit 0
else
    echo "✗✗✗ TEST FAILED ✗✗✗"
    echo "For debugging, re-run with --keep flag:"
    echo "  bash test_predict_standalone.sh --keep"
    exit 1
fi
