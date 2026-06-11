#!/bin/bash
#
# Wrapper: Call original organizeinputs.py, then ADD demographic file
#
# This script:
# 1. Calls the ORIGINAL organizeinputs.py with rules.json (UNCHANGED)
# 2. ONLY ADDS: demographic_features.csv to each subject folder
#
# Usage: Same as process_series.sh
#   bash organize_and_predict.sh <hpc_scratch_dir>

set -u

scratch=$1
input_dir="$scratch/input"
output_dir="$scratch/output"
log_file="$scratch/job.log"

mkdir -p "$output_dir"

exec > >(tee -a "$log_file") 2>&1

echo "=========================================="
echo "DICOM Organization + Add Demographics"
echo "=========================================="
echo "Scratch:   $scratch"
echo "Input:     $input_dir"
echo "Output:    $output_dir"
echo "Started:   $(date -u +%Y-%m-%dT%H-%M-%SZ)"
echo "=========================================="
echo ""

if [ ! -d "$input_dir" ]; then
    echo "!! Input directory missing: $input_dir"
    touch "$scratch/.organize_failed"
    exit 2
fi

# --- python environment ---

CONDA_ENV=/lab-share/Rad-Warfield-e2/Groups/Imp-Recons/prabhjot/work/gits/fcd4pacs/MAP/fcd_env

if [ ! -x "$CONDA_ENV/bin/python3" ]; then
    echo "!! No python3 at $CONDA_ENV/bin/python3"
    touch "$scratch/.organize_failed"
    exit 3
fi

export PATH="$CONDA_ENV/bin:$PATH"
echo "Python: $(which python3) ($(python3 --version 2>&1))"
echo ""

# --- Step 1: Run ORIGINAL organizeinputs.py (UNCHANGED) ---

REPO_ROOT=/lab-share/Rad-Warfield-e2/Groups/Imp-Recons/prabhjot/work/gits/pacs_FCDdetection
ORGANIZER="$REPO_ROOT/organizeinputs/organizeinputs.py"
RULES="$REPO_ROOT/organizeinputs/rules.json"

DCM2NIIX_SIF="${DCM2NIIX_SIF:-$REPO_ROOT/containers/dcm2niix.sif}"
SINGULARITY_BIN="${SINGULARITY_BIN:-singularity}"

if [ ! -f "$ORGANIZER" ]; then
    echo "!! organizeinputs.py not found: $ORGANIZER"
    touch "$scratch/.organize_failed"
    exit 4
fi
if [ ! -f "$RULES" ]; then
    echo "!! rules.json not found: $RULES"
    touch "$scratch/.organize_failed"
    exit 5
fi
if [ ! -f "$DCM2NIIX_SIF" ]; then
    echo "!! dcm2niix.sif not found: $DCM2NIIX_SIF"
    touch "$scratch/.organize_failed"
    exit 6
fi
if ! command -v "$SINGULARITY_BIN" >/dev/null 2>&1; then
    if command -v module >/dev/null 2>&1; then
        module load singularity 2>/dev/null || true
    fi
fi
if ! command -v "$SINGULARITY_BIN" >/dev/null 2>&1; then
    echo "!! singularity not on PATH"
    touch "$scratch/.organize_failed"
    exit 7
fi

echo "Running organizeinputs.py (ORIGINAL)"
echo "  rules:        $RULES"
echo "  dcm2niix sif: $DCM2NIIX_SIF"
echo ""

python3 "$ORGANIZER" \
    --in-dir "$input_dir" \
    --out-dir "$output_dir" \
    --dcm2niix-sif "$DCM2NIIX_SIF" \
    --singularity "$SINGULARITY_BIN" \
    --rules "$RULES"
rc=$?

echo ""
echo "organizeinputs.py finished: $(date -u +%Y-%m-%dT%H-%M-%SZ), rc=$rc"

if [ $rc -ne 0 ]; then
    touch "$scratch/.organize_failed"
    echo "Touched $scratch/.organize_failed (see $output_dir/triage_report.json)"
    exit $rc
fi

touch "$scratch/.organize_done"
echo "Touched $scratch/.organize_done"

# --- Step 2: ADD DEMOGRAPHIC FILES (NEW) ---

echo ""
echo "=========================================="
echo "Adding Demographic Files"
echo "=========================================="
echo ""

# Look for MELD_* folders in output_dir/meld/input/
# These are created by organizeinputs.py
MELD_INPUT_BASE="$output_dir/meld/input"

if [ ! -d "$MELD_INPUT_BASE" ]; then
    echo "ERROR: MELD input directory not found: $MELD_INPUT_BASE"
    exit 10
fi

for meld_subj_dir in "$MELD_INPUT_BASE"/MELD_*; do
    if [ -d "$meld_subj_dir" ]; then
        subj_name=$(basename "$meld_subj_dir")
        demo_file="$meld_subj_dir/demographic_features.csv"
        
        echo "Subject: $subj_name"
        
        if [ -f "$demo_file" ]; then
            echo "  ✓ Demographic file already exists"
        else
            echo "  Creating demographic_features.csv..."
            
            # Default values
            age=30
            sex="unknown"
            
            # Scan input directory for DICOM files and extract DOB/DOS/Sex
            python3 << EXTRACT_DEMO > /tmp/demo_extract.txt 2>&1
import os
import sys
from datetime import datetime

age = 30
sex = 'unknown'
input_dir = '$input_dir'

try:
    import pydicom
    
    sys.stderr.write(f"Scanning: {input_dir}\n")
    
    # Walk through all files in input directory
    all_files = []
    for root, dirs, files in os.walk(input_dir):
        for fname in files:
            all_files.append(os.path.join(root, fname))
    
    sys.stderr.write(f"Found {len(all_files)} files total\n")
    
    # Try to read each file until we get DOB, DOS, and Sex
    for dcm_path in sorted(all_files):
        try:
            sys.stderr.write(f"Trying: {os.path.basename(dcm_path)}\n")
            ds = pydicom.dcmread(dcm_path, stop_before_pixels=True)
            
            # Check if we have the fields we need
            has_dob = hasattr(ds, 'PatientBirthDate') and str(ds.PatientBirthDate).strip()
            has_dos = hasattr(ds, 'StudyDate') and str(ds.StudyDate).strip()
            has_sex = hasattr(ds, 'PatientSex') and str(ds.PatientSex).strip()
            
            sys.stderr.write(f"  DOB: {has_dob}, DOS: {has_dos}, Sex: {has_sex}\n")
            
            # If we have what we need, extract and move on
            if has_dob and has_dos and has_sex:
                sys.stderr.write(f"  ✓ Found complete record\n")
                
                # Extract DOB
                dob = None
                try:
                    dob_str = str(ds.PatientBirthDate).strip()
                    if len(dob_str) == 8:
                        dob = datetime.strptime(dob_str, '%Y%m%d')
                except:
                    pass
                
                # Extract DOS
                dos = None
                try:
                    dos_str = str(ds.StudyDate).strip()
                    if len(dos_str) == 8:
                        dos = datetime.strptime(dos_str, '%Y%m%d')
                except:
                    pass
                
                # Calculate age
                if dob and dos:
                    age = (dos - dob).days // 365
                    sys.stderr.write(f"  Age calculated: {age}\n")
                
                # Extract sex
                sex_str = str(ds.PatientSex).strip().upper()
                if sex_str in ['M', 'MALE']:
                    sex = 'male'
                elif sex_str in ['F', 'FEMALE']:
                    sex = 'female'
                sys.stderr.write(f"  Sex: {sex}\n")
                
                print(f'{age}|{sex}')
                sys.exit(0)
        
        except Exception as e:
            sys.stderr.write(f"  Could not read: {str(e)[:50]}\n")
            pass
    
    sys.stderr.write(f"No DICOM with complete DOB/DOS/Sex found\n")
    print(f'{age}|{sex}')
    
except ImportError:
    sys.stderr.write("pydicom not installed\n")
    print(f'{age}|{sex}')
except Exception as e:
    sys.stderr.write(f"Error: {e}\n")
    print(f'{age}|{sex}')
EXTRACT_DEMO
            
            # Read extracted values
            if [ -f /tmp/demo_extract.txt ]; then
                # Show debug output
                echo "  Debug output:" >&2
                cat /tmp/demo_extract.txt >&2
                
                extracted=$(cat /tmp/demo_extract.txt | tail -1)
                if [ -n "$extracted" ]; then
                    age=$(echo "$extracted" | cut -d'|' -f1)
                    sex=$(echo "$extracted" | cut -d'|' -f2)
                fi
                rm /tmp/demo_extract.txt
            fi

            
            # Extract site code from subject name (e.g., MELD_H52_3T_FCD_... -> H52)
            harmo_code=$(echo "$subj_name" | cut -d'_' -f2)
            
            # Create demographic_features.csv at subject folder ROOT level
            # This goes ALONGSIDE T1/ and FLAIR/ folders, not inside them
            cat > "$demo_file" << 'EOF'
"ID","Harmo code (harmonisation code, put "noHarmo" if not using harmonisation)","Group ("patient" or "control")","Age at preoperative (in years)","Sex ("female" or "male")"
EOF
            
            echo "\"$subj_name\",\"$harmo_code\",\"patient\",$age,\"$sex\"" >> "$demo_file"
            
            echo "  ✓ Created: demographic_features.csv"
            echo "    Path:  $meld_subj_dir/demographic_features.csv"
            echo "    Age:   $age"
            echo "    Sex:   $sex"
        fi
        echo ""
    fi
done

echo ""
echo "=========================================="
echo "COMPLETE"
echo "=========================================="
echo "Output: $output_dir"
echo ""
echo "Demographic files are placed at:"
echo "  <subject_folder>/demographic_features.csv"
echo ""
echo "Alongside T1 and FLAIR folders"
echo "Finished: $(date -u +%Y-%m-%dT%H-%M-%SZ)"

exit 0
