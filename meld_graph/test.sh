SIF=/lab-share/Rad-Warfield-e2/Groups/Imp-Recons/prabhjot/work/gits/pacs_FCDdetection/containers/meld_graph.sif
LICENSE=/lab-share/Rad-Warfield-e2/Groups/Imp-Recons/prabhjot/work/gits/MELDgraph2026/meld_graph/license.txt
TEST_DATA=/lab-share/Rad-Warfield-e2/Groups/Imp-Recons/prabhjot/tmp/meld_test_20260429_174139/output/meld

# Put license inside /data
cp $LICENSE $TEST_DATA/license.txt

# Try help again WITH the bind
singularity exec --bind $TEST_DATA:/data $SIF \
    python /app/scripts/new_patient_pipeline/new_pt_pipeline.py --help




