#!/bin/bash -l
#PBS -l nodes=16:ppn=24
#PBS -l walltime=04:00:00
#PBS -m abe
#PBS -M slaughter@cs.stanford.edu

cd "$PBS_O_WORKDIR"



mpirun -n 1 -npernode 1 -bind-to none --hostfile "$PBS_NODEFILE" ../ebb --partition --legion -a '-ll:cpu 8 -ll:util 1 -ll:dma 2 -ll:csize 32000 -hl:sched 4096 -level default_mapper=5 -logfile prof_strong_1_%.log' -r legionprof ../../soleil-x/src/soleil-x.t -f ../../soleil-x/testcases/taylor_green_vortex/taylor_green_vortex_312_312_312.lua -x 2 -y 2 -z 2 | tee out_strong_1.log
mpirun -n 2 -npernode 1 -bind-to none --hostfile "$PBS_NODEFILE" ../ebb --partition --legion -a '-ll:cpu 8 -ll:util 1 -ll:dma 2 -ll:csize 32000 -hl:sched 4096 -level default_mapper=5 -logfile prof_strong_2_%.log' -r legionprof ../../soleil-x/src/soleil-x.t -f ../../soleil-x/testcases/taylor_green_vortex/taylor_green_vortex_312_312_312.lua -x 4 -y 2 -z 2 | tee out_strong_2.log
mpirun -n 4 -npernode 1 -bind-to none --hostfile "$PBS_NODEFILE" ../ebb --partition --legion -a '-ll:cpu 8 -ll:util 1 -ll:dma 2 -ll:csize 32000 -hl:sched 4096 -level default_mapper=5 -logfile prof_strong_4_%.log' -r legionprof ../../soleil-x/src/soleil-x.t -f ../../soleil-x/testcases/taylor_green_vortex/taylor_green_vortex_312_312_312.lua -x 4 -y 4 -z 2 | tee out_strong_4.log
mpirun -n 6 -npernode 1 -bind-to none --hostfile "$PBS_NODEFILE" ../ebb --partition --legion -a '-ll:cpu 8 -ll:util 1 -ll:dma 2 -ll:csize 32000 -hl:sched 4096 -level default_mapper=5 -logfile prof_strong_6_%.log' -r legionprof ../../soleil-x/src/soleil-x.t -f ../../soleil-x/testcases/taylor_green_vortex/taylor_green_vortex_312_312_312.lua -x 4 -y 4 -z 3 | tee out_strong_6.log
mpirun -n 8 -npernode 1 -bind-to none --hostfile "$PBS_NODEFILE" ../ebb --partition --legion -a '-ll:cpu 8 -ll:util 1 -ll:dma 2 -ll:csize 32000 -hl:sched 4096 -level default_mapper=5 -logfile prof_strong_8_%.log' -r legionprof ../../soleil-x/src/soleil-x.t -f ../../soleil-x/testcases/taylor_green_vortex/taylor_green_vortex_312_312_312.lua -x 4 -y 4 -z 4 | tee out_strong_8.log
mpirun -n 12 -npernode 1 -bind-to none --hostfile "$PBS_NODEFILE" ../ebb --partition --legion -a '-ll:cpu 8 -ll:util 1 -ll:dma 2 -ll:csize 32000 -hl:sched 4096 -level default_mapper=5 -logfile prof_strong_12_%.log' -r legionprof ../../soleil-x/src/soleil-x.t -f ../../soleil-x/testcases/taylor_green_vortex/taylor_green_vortex_312_312_312.lua -x 6 -y 4 -z 4 | tee out_strong_12.log
mpirun -n 16 -npernode 1 -bind-to none --hostfile "$PBS_NODEFILE" ../ebb --partition --legion -a '-ll:cpu 8 -ll:util 1 -ll:dma 2 -ll:csize 32000 -hl:sched 4096 -level default_mapper=5 -logfile prof_strong_16_%.log' -r legionprof ../../soleil-x/src/soleil-x.t -f ../../soleil-x/testcases/taylor_green_vortex/taylor_green_vortex_312_312_312.lua -x 8 -y 4 -z 4 | tee out_strong_16.log



mpirun -n 1 -npernode 1 -bind-to none --hostfile "$PBS_NODEFILE" ../ebb --partition --legion -a '-ll:cpu 8 -ll:util 1 -ll:dma 2 -ll:csize 26000 -hl:sched 4096 -level default_mapper=5 -logfile prof_weak_1_%.log' -r legionprof ../../soleil-x/src/soleil-x.t -f ../../soleil-x/testcases/taylor_green_vortex/taylor_green_vortex_384_384_192.lua -x 2 -y 2 -z 2 | tee out_weak_1.log
mpirun -n 2 -npernode 1 -bind-to none --hostfile "$PBS_NODEFILE" ../ebb --partition --legion -a '-ll:cpu 8 -ll:util 1 -ll:dma 2 -ll:csize 26000 -hl:sched 4096 -level default_mapper=5 -logfile prof_weak_2_%.log' -r legionprof ../../soleil-x/src/soleil-x.t -f ../../soleil-x/testcases/taylor_green_vortex/taylor_green_vortex_384_384_384.lua -x 4 -y 2 -z 2 | tee out_weak_2.log
mpirun -n 4 -npernode 1 -bind-to none --hostfile "$PBS_NODEFILE" ../ebb --partition --legion -a '-ll:cpu 8 -ll:util 1 -ll:dma 2 -ll:csize 30000 -hl:sched 4096 -level default_mapper=5 -logfile prof_weak_4_%.log' -r legionprof ../../soleil-x/src/soleil-x.t -f ../../soleil-x/testcases/taylor_green_vortex/taylor_green_vortex_768_384_384.lua -x 4 -y 4 -z 2 | tee out_weak_4.log
mpirun -n 8 -npernode 1 -bind-to none --hostfile "$PBS_NODEFILE" ../ebb --partition --legion -a '-ll:cpu 8 -ll:util 1 -ll:dma 2 -ll:csize 30000 -hl:sched 4096 -level default_mapper=5 -logfile prof_weak_8_%.log' -r legionprof ../../soleil-x/src/soleil-x.t -f ../../soleil-x/testcases/taylor_green_vortex/taylor_green_vortex_768_768_384.lua -x 4 -y 4 -z 4 | tee out_weak_8.log
mpirun -n 16 -npernode 1 -bind-to none --hostfile "$PBS_NODEFILE" ../ebb --partition --legion -a '-ll:cpu 8 -ll:util 1 -ll:dma 2 -ll:csize 30000 -hl:sched 4096 -level default_mapper=5 -logfile prof_weak_16_%.log' -r legionprof ../../soleil-x/src/soleil-x.t -f ../../soleil-x/testcases/taylor_green_vortex/taylor_green_vortex_768_768_768.lua -x 8 -y 4 -z 4 | tee out_weak_16.log
