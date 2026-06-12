#!/usr/bin/env python3
"""
Direct nnUNet prediction with explicit path configuration.
Sets nnUNet environment BEFORE importing nnunet modules to avoid inference bugs.
"""
import sys
import os
from pathlib import Path

# CRITICAL: Set nnUNet paths BEFORE any nnunet imports
os.environ['nnUNet_results'] = '/opt/nnunet_models'
os.environ['nnUNet_raw'] = '/tmp/nnunet_raw'
os.environ['nnUNet_preprocessed'] = '/tmp/nnunet_preprocessed'

# NOW safe to import
from nnunetv2.inference.predict_from_raw_data import nnUNetPredictor
import glob

def main():
    input_dir = sys.argv[1]
    output_dir = sys.argv[2]
    
    print(f"\n{'='*60}")
    print(f"nnUNet Prediction (Direct API)")
    print(f"{'='*60}")
    print(f"Input:  {input_dir}")
    print(f"Output: {output_dir}")
    print()
    
    # Verify input exists
    if not os.path.isdir(input_dir):
        print(f"ERROR: Input directory not found: {input_dir}")
        return 1
    
    # Get input files
    input_files = sorted(glob.glob(os.path.join(input_dir, '*.nii.gz')))
    print(f"Input files ({len(input_files)}):")
    for f in input_files:
        print(f"  {os.path.basename(f)}")
    
    if len(input_files) == 0:
        print("ERROR: No input files found!")
        return 1
    
    # Create output dir
    os.makedirs(output_dir, exist_ok=True)
    
    # Initialize predictor
    print(f"\nInitializing predictor...")
    predictor = nnUNetPredictor(
        tile_step_size=0.5,
        use_gaussian=True,
        use_mirroring=False,
    )
    
    print(f"Loading model from: /opt/nnunet_models/Dataset003_Combined/nnUNetTrainer__nnUNetPlans__3d_fullres")
    predictor.initialize_from_trained_model_folder(
        '/opt/nnunet_models/Dataset003_Combined/nnUNetTrainer__nnUNetPlans__3d_fullres',
        use_folds=(0, 1, 2, 3, 4),
        checkpoint_name='checkpoint_best.pth',
    )
    
    print(f"\nPredicting...")
    predictor.predict_from_files(
        list_of_lists=[input_files],
        output_folder=output_dir,
        save_probabilities=False,
        overwrite=True,
    )
    
    print(f"\n✓ Prediction complete!")
    print(f"Output: {output_dir}")
    
    # List output files
    output_files = glob.glob(os.path.join(output_dir, '*.nii.gz'))
    print(f"\nOutput files ({len(output_files)}):")
    for f in output_files:
        size = os.path.getsize(f) / (1024*1024)
        print(f"  {os.path.basename(f)} ({size:.1f} MB)")
    
    return 0

if __name__ == "__main__":
    if len(sys.argv) < 3:
        print(f"Usage: {sys.argv[0]} <input_dir> <output_dir>")
        sys.exit(1)
    
    sys.exit(main())
