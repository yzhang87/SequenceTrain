#!/bin/bash

# Copyright 2012-2013 Karel Vesely, Daniel Povey
# Apache 2.0

# Begin configuration section.  
nnet= # Optionally pre-select network to use for getting state-likelihoods
feature_transform= # Optionally pre-select feature transform (in front of nnet)
model= # Optionally pre-select transition model
class_frame_counts= # Optionally pre-select class-counts used to compute PDF priors 

stage=0 # stage=1 skips lattice generation
nj=4
cmd=run.pl
max_active=7000 # maximum of active tokens
min_active=200 #minimum of active tokens
max_mem=50000000 # limit the fst-size to 50MB (larger fsts are minimized)
beam=13.0 # GMM:13.0
latbeam=8.0 # GMM:6.0
acwt=0.10 # GMM:0.0833, note: only really affects pruning (scoring is on lattices).
scoring_opts="--min-lmwt 1 --max-lmwt 10"
skip_scoring=false
use_gpu_id=-1 # disable gpu
#parallel_opts="-pe smp 2" # use 2 CPUs (1 DNN-forward, 1 decoder)
parallel_opts= # use 2 CPUs (1 DNN-forward, 1 decoder)
# End configuration section.

echo "$0 $@"  # Print the command line for logging

[ -f ./path.sh ] && . ./path.sh; # source the path.
. parse_options.sh || exit 1;

if [ $# != 8 ]; then
   echo "Usage: $0 [options] <graph-dir> <data-dir> <decode-dir>"
   echo "... where <decode-dir> is assumed to be a sub-directory of the directory"
   echo " where the DNN + transition model is."
   echo "e.g.: $0 exp/dnn1/graph_tgpr data/test exp/dnn1/decode_tgpr"
   echo ""
   echo "This script works on plain or modified features (CMN,delta+delta-delta),"
   echo "which are then sent through feature-transform. It works out what type"
   echo "of features you used from content of srcdir."
   echo ""
   echo "main options (for others, see top of script file)"
   echo "  --config <config-file>                           # config containing options"
   echo "  --nj <nj>                                        # number of parallel jobs"
   echo "  --cmd (utils/run.pl|utils/queue.pl <queue opts>) # how to run jobs."
   echo ""
   echo "  --nnet <nnet>                                    # which nnet to use (opt.)"
   echo "  --feature-transform <nnet>                       # select transform in front of nnet (opt.)"
   echo "  --class-frame-counts <file>                      # file with frame counts (used to compute priors) (opt.)"
   echo "  --model <model>                                  # which transition model to use (opt.)"
   echo ""
   echo "  --acwt <float>                                   # select acoustic scale for decoding"
   echo "  --scoring-opts <opts>                            # options forwarded to local/score.sh"
   exit 1;
fi


graphdir=$1
data=$2
dir=$3
srcdir=`dirname $dir`; # The model directory is one level up from decoding directory.
sdata=$data/split$nj;

cnbin=$4
cnconfig=$5
cntkModel=$6
labelDim=$7
featDim=$8

mkdir -p $dir/log
[[ -d $sdata && $data/feats.scp -ot $sdata ]] || split_data.sh $data $nj || exit 1;
echo $nj > $dir/num_jobs

if [ -z "$model" ]; then # if --model <mdl> was not specified on the command line...
  if [ -z $iter ]; then model=$srcdir/final.mdl; 
  else model=$srcdir/$iter.mdl; fi
fi

for f in $model $graphdir/HCLG.fst; do
  [ ! -f $f ] && echo "decode_cntk_nnet.sh: no such file $f" && exit 1;
done


# check that files exist
for f in $sdata/1/feats.scp $model $graphdir/HCLG.fst; do
  [ ! -f $f ] && echo "$0: no such file $f" && exit 1;
done

# PREPARE THE LOG-POSTERIOR COMPUTATION PIPELINE
if [ -z "$class_frame_counts" ]; then
  class_frame_counts=$srcdir/ali_train_pdf.counts
else
  echo "Overriding class_frame_counts by $class_frame_counts"
fi

# Create the feature stream:
feats="scp:$sdata/JOB/feats.scp"
inputfeats="$sdata/JOB/cntkInput.scp"
outputfeats="$sdata/JOB/cntkOutput.scp"


if [ ! -f $sdata/JOB/sls.scp ]; then
    $cmd JOB=1:$nj $dir/log/split_input.JOB.log \
        perl /data/sls/babel/scripts/kaldi/utils/createCNTKinputList.pl $sdata/JOB/ $data/sls.scp
fi

# Run the decoding in the queue
if [ $stage -le 0 ]; then
  $cmd $parallel_opts JOB=1:$nj $dir/log/decode.JOB.log \
    $cnbin configFile=$cnconfig model=$cntkModel inputSCP=$inputfeats outputSCP=$outputfeats labelDim=$labelDim featDim=$featDim \| \
    latgen-faster-mapped --min-active=$min_active --max-active=$max_active --max-mem=$max_mem --beam=$beam --lattice-beam=$latbeam \
    --acoustic-scale=$acwt --allow-partial=true --word-symbol-table=$graphdir/words.txt \
    $model $graphdir/HCLG.fst ark:- "ark:|gzip -c > $dir/lat.JOB.gz" || exit 1;
fi

# Run the scoring
if ! $skip_scoring ; then
  [ ! -x local/score.sh ] && \
    echo "Not scoring because local/score.sh does not exist or not executable." && exit 1;
  local/score.sh $scoring_opts --cmd "$cmd" $data $graphdir $dir || exit 1;
fi

exit 0;
