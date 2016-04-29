#!/bin/bash

set -e

mkdir "$1"

# Not sure there's really a point to this if I'm not going to actually get a viable local build.

# make clean
# make -j12

cp ./run_ebb.sh "$1"
