#!/bin/bash
#SBATCH --job-name=nnunet_predict
#SBATCH --time=02:00:00
#SBATCH --mem=32GB
#SBATCH --gres=gpu:1
#SBATCH --partition=bch-gpu
#SBATCH --output=%x_%j.log

set -u

scratch="${1:?Usage: sbatch $0 <hpc_scratch_dir>}"
input_dir="$scratch/output/nnunet/Dataset003_FCD/imagesTs"
output_dir="$scratch/output/nnunet/Dataset003_FCD/PredictionTs"
registered_dir="$scratch/output/nnunet/Dataset003_FCD/registered"
log_file="$scratch/job_nnunet.log"

mkdir -p "$output_dir" "$registered_dir"
exec > >(tee -a "$log_file") 2>&1
sleep 20

echo "========================================================"
echo "nnUNet inference (Stage 2) - GPU Job"
echo "========================================================"
echo "SLURM Job ID: $SLURM_JOB_ID"
echo "GPU: $CUDA_VISIBLE_DEVICES"
echo "Started: $(date -u +%Y-%m-%dT%H-%M-%SZ)"
echo

# Validate inputs
if [ ! -d "$input_dir" ]; then
    echo "!! Input directory missing"
    touch "$scratch/.nnunet_failed"
    exit 1
fi

T1W=$(find "$input_dir" -maxdepth 1 -name "*_0000.nii.gz" | head -1)
FLAIR=$(find "$input_dir" -maxdepth 1 -name "*_0001.nii.gz" | head -1)

if [ -z "$T1W" ] || [ -z "$FLAIR" ]; then
    echo "!! Missing T1w or FLAIR"
    touch "$scratch/.nnunet_failed"
    exit 2
fi

CASE_ID=$(basename "$T1W" | sed 's/_0000.nii.gz//')
echo "Case: $CASE_ID"
echo

# Locate container
NNUNET_SIF="${NNUNET_SIF:-/lab-share/Rad-Warfield-e2/Groups/Imp-Recons/prabhjot/work/gits/pacs_FCDdetection/containers/nnunet.sif}"

if [ ! -f "$NNUNET_SIF" ]; then
    echo "!! Container not found"
    touch "$scratch/.nnunet_failed"
    exit 3
fi

# Create registration script
cat > "$scratch/register_and_predict.py" << 'PYPROG'
#!/usr/bin/env python3
import sys, os
from pathlib import Path
import SimpleITK as sitk

def register_flair_to_t1(t1_path, flair_path, output_dir):
    print(f"\n{'='*60}")
    print(f"Registration: FLAIR → T1w (Rigid)")
    print(f"{'='*60}")
    
    # Load original images WITHOUT resampling
    t1_orig = sitk.ReadImage(t1_path, sitk.sitkFloat32)
    flair_orig = sitk.ReadImage(flair_path, sitk.sitkFloat32)
    
    t1_spacing = t1_orig.GetSpacing()
    flair_spacing = flair_orig.GetSpacing()
    t1_size = t1_orig.GetSize()
    flair_size = flair_orig.GetSize()
    
    print(f"\nLoading images:")
    print(f"  T1w:   {t1_size}, spacing {[f'{s:.3f}' for s in t1_spacing]}")
    print(f"  FLAIR: {flair_size}, spacing {[f'{s:.3f}' for s in flair_spacing]}")
    
    # Use originals for registration (NO resampling to 1mm)
    fixed_image = t1_orig
    moving_image = flair_orig
    
    print(f"\nSetting up Rigid registration...")
    registration_method = sitk.ImageRegistrationMethod()
    registration_method.SetMetricAsMattesMutualInformation(numberOfHistogramBins=50)
    registration_method.SetMetricSamplingStrategy(registration_method.RANDOM)
    registration_method.SetMetricSamplingPercentage(0.01)
    registration_method.SetInterpolator(sitk.sitkLinear)
    registration_method.SetOptimizerAsGradientDescent(
        learningRate=1.0, numberOfIterations=100,
        convergenceMinimumValue=1e-6, convergenceWindowSize=10
    )
    registration_method.SetOptimizerScalesFromPhysicalShift()
    registration_method.SetShrinkFactorsPerLevel(shrinkFactors=[4, 2, 1])
    registration_method.SetSmoothingSigmasPerLevel(smoothingSigmas=[2, 1, 0])
    registration_method.SmoothingSigmasAreSpecifiedInPhysicalUnitsOn()
    
    initial_transform = sitk.CenteredTransformInitializer(
        fixed_image, moving_image, sitk.Euler3DTransform(),
        sitk.CenteredTransformInitializerFilter.GEOMETRY
    )
    registration_method.SetInitialTransform(initial_transform, inPlace=False)
    
    print(f"Running registration...")
    final_transform = registration_method.Execute(fixed_image, moving_image)
    
    print(f"\nResampling FLAIR to T1w space (preserving T1w size/spacing)...")
    # Resample FLAIR to match T1w EXACTLY (same size, spacing, origin)
    resampled_image = sitk.Resample(
        moving_image,
        fixed_image,  # Use T1w as template
        final_transform,
        sitk.sitkLinear,
        0.0,
        sitk.sitkFloat32
    )
    
    Path(output_dir).mkdir(parents=True, exist_ok=True)
    flair_out = str(Path(output_dir) / "FLAIR_registered.nii.gz")
    t1w_out = str(Path(output_dir) / "T1w_registered.nii.gz")
    
    sitk.WriteImage(resampled_image, flair_out)
    sitk.WriteImage(fixed_image, t1w_out)
    
    print(f"  ✓ Saved registered images")
    print(f"    T1w output:   {fixed_image.GetSize()}")
    print(f"    FLAIR output: {resampled_image.GetSize()}")
    return flair_out, t1w_out

def main():
    t1_path = sys.argv[1]
    flair_path = sys.argv[2]
    output_dir = sys.argv[3]
    case_id = sys.argv[4]
    
    print(f"Case: {case_id}")
    flair_reg, t1w_reg = register_flair_to_t1(t1_path, flair_path, output_dir)
    
    import shutil
    shutil.copy(t1w_reg, t1_path)
    shutil.copy(flair_reg, flair_path)
    
    print(f"\n✓ Registration complete")
    return 0

if __name__ == "__main__":
    sys.exit(main())
PYPROG
sleep 30


chmod +x "$scratch/register_and_predict.py"

SINGULARITY_BIN="${SINGULARITY_BIN:-singularity}"


echo "Running registration inside container..."
echo

$SINGULARITY_BIN exec --nv \
    --bind /lab-share:/lab-share \
    "$NNUNET_SIF" python3 "$scratch/register_and_predict.py" \
    "$T1W" "$FLAIR" "$registered_dir" "$CASE_ID"


if [ $? -ne 0 ]; then
    echo "!! Registration failed"
    touch "$scratch/.nnunet_failed"
    exit 4
fi

echo
echo "========================================================"
echo "Running nnUNet prediction (GPU)"
echo "========================================================"
echo

# Use nnUNetv2_predict CLI with GPU
$SINGULARITY_BIN exec --nv \
    --bind /lab-share:/lab-share \
    "$NNUNET_SIF" \
    nnUNetv2_predict \
    -i "$input_dir" \
    -o "$output_dir" \
    -d Dataset003_Combined \
    -tr nnUNetTrainer \
    -c 3d_fullres \
    -f 0 1 2 3 4 \
    -step_size 0.5 \
    -chk checkpoint_best.pth \
    --disable_tta

rc=$?

if [ $rc -ne 0 ]; then
    echo "!! nnUNet prediction failed (rc=$rc)"
    touch "$scratch/.nnunet_failed"
    exit 5
fi

# Check output
if [ ! -d "$output_dir" ] || [ "$(find "$output_dir" -name "*.nii.gz" | wc -l)" -eq 0 ]; then
    echo "!! No predictions in output directory"
    touch "$scratch/.nnunet_failed"
    exit 6
fi

touch "$scratch/.nnunet_done"

echo
echo "========================================================"
echo "✓ COMPLETE"
echo "========================================================"
echo "Predictions: $output_dir"
ls -lh "$output_dir"/*.nii.gz
echo
echo "Finished: $(date -u +%Y-%m-%dT%H-%M-%SZ)"

exit 0
