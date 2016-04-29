#!/bin/bash -l
#PBS -l nodes=16:ppn=24
#PBS -l walltime=04:00:00
#PBS -m abe
#PBS -M slaughter@cs.stanford.edu

cd "$PBS_O_WORKDIR"


for f in $(uniq $PBS_NODEFILE); do
mpirun -n 1 -npernode 1 -bind-to none -H $f ../ebb --partition --legion -a "-ll:cpu 8 -ll:util 1 -ll:dma 2 -ll:csize 32000 -hl:sched 4096 -level default_mapper=5 -logfile log_strong_${f}_%.log" ../../soleil-x/src/soleil-x.t -f ../../soleil-x/testcases/taylor_green_vortex/taylor_green_vortex_312_312_312.lua -x 2 -y 2 -z 2 | tee test_strong_$f.log &
done
