#!/usr/bin/env python3
"""
register_t1w_flair.py

Register FLAIR to T1w using SimpleITK + elastix.
- Fixed image: T1w (anatomy)
- Moving image: FLAIR (functional, lesion-specific)
- Method: Multiresolution (affine → B-spline)
- Output: Registered FLAIR, transform maps, resampled pair at common spacing

Usage:
    python3 register_t1w_flair.py \
        --t1w T1w_ras.nii.gz \
        --flair FLAIR_ras.nii.gz \
        --output-dir /path/to/registered \
        [--tfm-dir /path/to/transforms] \
        [--resample-spacing 1.0]

Or import:
    from register_t1w_flair import register_and_resample
    t1w, flair, tfm_dir = register_and_resample(
        t1w_path, flair_path, output_dir, tfm_dir
    )
"""

import sys
import os
import argparse
import json
from pathlib import Path

try:
    import SimpleITK as sitk
except ImportError:
    print("Error: SimpleITK not found. Install with: pip install SimpleITK")
    sys.exit(1)


def register_and_resample(
    t1w_path,
    flair_path,
    output_dir,
    tfm_dir=None,
    resample_spacing=None,
    verbose=True,
):
    """
    Register FLAIR to T1w and return paths to registered images.

    Args:
        t1w_path (str): Path to T1w image (fixed).
        flair_path (str): Path to FLAIR image (moving).
        output_dir (str): Directory for registered outputs.
        tfm_dir (str, optional): Directory for transform files. 
                                 Defaults to output_dir/transforms.
        resample_spacing (float, optional): Target voxel spacing (mm) for output.
                                           If None, uses T1w spacing.
        verbose (bool): Print progress messages.

    Returns:
        tuple: (t1w_output_path, flair_output_path, tfm_dir)
    """
    output_dir = Path(output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)

    if tfm_dir is None:
        tfm_dir = output_dir / "transforms"
    tfm_dir = Path(tfm_dir)
    tfm_dir.mkdir(parents=True, exist_ok=True)

    if verbose:
        print(f"Loading T1w (fixed): {t1w_path}")
    fixed = sitk.ReadImage(str(t1w_path), sitk.sitkFloat32)
    if verbose:
        print(
            f"  Shape: {fixed.GetSize()}, "
            f"Spacing: {fixed.GetSpacing()}, "
            f"Origin: {fixed.GetOrigin()}"
        )

    if verbose:
        print(f"Loading FLAIR (moving): {flair_path}")
    moving = sitk.ReadImage(str(flair_path), sitk.sitkFloat32)
    if verbose:
        print(
            f"  Shape: {moving.GetSize()}, "
            f"Spacing: {moving.GetSpacing()}, "
            f"Origin: {moving.GetOrigin()}"
        )

    # Multiresolution registration: affine → B-spline deformation
    if verbose:
        print("Setting up elastix parameter maps (affine + B-spline)...")

    elastix_params = [
        sitk.GetDefaultParameterMap("affine"),
        sitk.GetDefaultParameterMap("bspline"),
    ]

    # Optionally reduce affine iterations for speed
    elastix_params[0]["MaximumNumberOfIterations"] = ["256"]
    elastix_params[1]["MaximumNumberOfIterations"] = ["256"]

    if verbose:
        print("Running elastix registration...")

    elastix = sitk.ElastixImageFilter()
    elastix.SetFixedImage(fixed)
    elastix.SetMovingImage(moving)
    for params in elastix_params:
        elastix.AddParameterMap(params)
    elastix.SetOutputDirectory(str(tfm_dir))
    elastix.LogToFileOn()

    try:
        elastix.Execute()
    except RuntimeError as e:
        print(f"Error: elastix registration failed: {e}", file=sys.stderr)
        raise

    # Get registered (warped) moving image
    registered_flair = elastix.GetResultImage()

    if verbose:
        print(
            f"  Registered FLAIR shape: {registered_flair.GetSize()}, "
            f"Spacing: {registered_flair.GetSpacing()}"
        )

    # Save registered FLAIR
    flair_output = output_dir / "FLAIR_registered.nii.gz"
    if verbose:
        print(f"Saving registered FLAIR: {flair_output}")
    sitk.WriteImage(registered_flair, str(flair_output))

    # Save T1w (copy for consistency, already in RAS)
    t1w_output = output_dir / "T1w_registered.nii.gz"
    if verbose:
        print(f"Saving T1w reference: {t1w_output}")
    sitk.WriteImage(fixed, str(t1w_output))

    # Optionally resample both to common spacing
    if resample_spacing is not None:
        if verbose:
            print(
                f"Resampling both images to {resample_spacing} mm isotropic spacing..."
            )

        target_spacing = (resample_spacing, resample_spacing, resample_spacing)

        # Resample T1w
        resampler = sitk.ResampleImageFilter()
        resampler.SetOutputSpacing(target_spacing)
        resampler.SetInterpolator(sitk.sitkLinear)
        t1w_resampled = resampler.Execute(fixed)

        t1w_output_resampled = output_dir / "T1w_registered_resampled.nii.gz"
        sitk.WriteImage(t1w_resampled, str(t1w_output_resampled))
        if verbose:
            print(f"  Saved: {t1w_output_resampled} ({t1w_resampled.GetSize()})")

        # Resample registered FLAIR
        flair_resampled = resampler.Execute(registered_flair)

        flair_output_resampled = output_dir / "FLAIR_registered_resampled.nii.gz"
        sitk.WriteImage(flair_resampled, str(flair_output_resampled))
        if verbose:
            print(f"  Saved: {flair_output_resampled} ({flair_resampled.GetSize()})")

    # Save metadata about the registration
    metadata = {
        "t1w_input": str(t1w_path),
        "flair_input": str(flair_path),
        "t1w_output": str(t1w_output),
        "flair_output": str(flair_output),
        "tfm_dir": str(tfm_dir),
        "fixed_image_shape": list(fixed.GetSize()),
        "fixed_image_spacing": list(fixed.GetSpacing()),
        "registered_flair_shape": list(registered_flair.GetSize()),
        "registered_flair_spacing": list(registered_flair.GetSpacing()),
        "method": "elastix (affine + B-spline)",
    }

    metadata_path = output_dir / "registration_metadata.json"
    with open(metadata_path, "w") as f:
        json.dump(metadata, f, indent=2)

    if verbose:
        print(f"Saved metadata: {metadata_path}")
        print("Registration complete.")

    return str(t1w_output), str(flair_output), str(tfm_dir)


def main():
    parser = argparse.ArgumentParser(
        description="Register FLAIR to T1w using SimpleITK + elastix"
    )
    parser.add_argument("--t1w", required=True, help="Path to T1w image (fixed)")
    parser.add_argument(
        "--flair", required=True, help="Path to FLAIR image (moving)"
    )
    parser.add_argument(
        "--output-dir",
        required=True,
        help="Output directory for registered images",
    )
    parser.add_argument(
        "--tfm-dir",
        help="Directory for transform files (default: output-dir/transforms)",
    )
    parser.add_argument(
        "--resample-spacing",
        type=float,
        help="Target isotropic voxel spacing (mm). If omitted, uses T1w spacing.",
    )
    parser.add_argument(
        "--quiet",
        action="store_true",
        help="Suppress progress output",
    )

    args = parser.parse_args()

    try:
        t1w_out, flair_out, tfm_dir = register_and_resample(
            args.t1w,
            args.flair,
            args.output_dir,
            tfm_dir=args.tfm_dir,
            resample_spacing=args.resample_spacing,
            verbose=not args.quiet,
        )
        print(f"\nSuccess!\n  T1w:   {t1w_out}\n  FLAIR: {flair_out}\n  TFM:   {tfm_dir}")
        return 0
    except Exception as e:
        print(f"Error: {e}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
