# Set caches to lab-share (same pattern as nnunet build)
export TMPDIR=/lab-share/Rad-Warfield-e2/Groups/Imp-Recons/prabhjot/tmp
export APPTAINER_CACHEDIR=$TMPDIR/apptainer_cache
export APPTAINER_TMPDIR=$TMPDIR/apptainer_tmp
export SINGULARITY_CACHEDIR=$APPTAINER_CACHEDIR
export SINGULARITY_TMPDIR=$APPTAINER_TMPDIR
mkdir -p $APPTAINER_CACHEDIR $APPTAINER_TMPDIR

# Clean the partial download from home dir
rm -rf ~/.apptainer/cache/blob ~/.singularity/cache 2>/dev/null

# Verify caches now point to lab-share
echo "Cache: $APPTAINER_CACHEDIR"
df -h $APPTAINER_CACHEDIR

# Now pull (run directly, not via the script that doesn't set env)


cd /lab-share/Rad-Warfield-e2/Groups/Imp-Recons/prabhjot/work/gits/MELDgraph2026/meld_graph
singularity pull --name meld_graph_gpu.sif docker://meldproject/meld_graph:v2.2.4_gpu
