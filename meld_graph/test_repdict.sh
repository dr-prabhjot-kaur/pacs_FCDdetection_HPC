# 1. Drop the new predict.sh into BOTH locations on HPC
# (use scp or whatever transfer method you've been using)


# Make executable
chmod +x /lab-share/Rad-Warfield-e2/Groups/Imp-Recons/prabhjot/work/gits/pacs_FCDdetection/meld_graph/predict.sh


# 2. Verify both fixes are in place
grep "APPTAINERENV_MELD_LICENSE=/data" /lab-share/Rad-Warfield-e2/Groups/Imp-Recons/prabhjot/work/gits/pacs_FCDdetection/meld_graph/predict.sh
# Should print:  export APPTAINERENV_MELD_LICENSE=/data/meld_license.txt

grep "meld_graph_gpu.sif" /lab-share/Rad-Warfield-e2/Groups/Imp-Recons/prabhjot/work/gits/pacs_FCDdetection/meld_graph/predict.sh
# Should print the SIF default line

# 3. Make sure the GPU sif is in containers/
ls -lh /lab-share/Rad-Warfield-e2/Groups/Imp-Recons/prabhjot/work/gits/pacs_FCDdetection/containers/meld_graph_gpu.sif
# If missing, copy it:
# cp /lab-share/Rad-Warfield-e2/Groups/Imp-Recons/prabhjot/work/gits/MELDgraph2026/meld_graph/meld_graph_gpu.sif \
#    /lab-share/Rad-Warfield-e2/Groups/Imp-Recons/prabhjot/work/gits/pacs_FCDdetection/containers/



# Set up fresh test scratch
TEST_SCRATCH=/lab-share/Rad-Warfield-e2/Groups/Imp-Recons/prabhjot/tmp/meld_test_20260513_234454 #meld_test_$(date +%Y%m%d_%H%M%S)
mkdir -p $TEST_SCRATCH/output/meld/input

# Copy test patient inputs (T1+FLAIR)
cp -r /lab-share/Rad-Warfield-e2/Groups/Imp-Recons/prabhjot/work/gits/pacs_FCDdetection/scratch/5651282_20260126_937a0e4c/output/meld/input/MELD_H52_3T_FCD_565128220260126 \
      $TEST_SCRATCH/output/meld/input/

echo "TEST_SCRATCH=$TEST_SCRATCH"

# Submit
sbatch /lab-share/Rad-Warfield-e2/Groups/Imp-Recons/prabhjot/work/gits/pacs_FCDdetection/meld_graph/predict.sh $TEST_SCRATCH

# Monitor
squeue -u $USER
sleep 30
tail -f $TEST_SCRATCH/meld_graph_job.log
