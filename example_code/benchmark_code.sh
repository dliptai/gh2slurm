#!/bin/bash
#SBATCH --job-name=benchmark
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=1
#SBATCH --time=00:01:00
#SBATCH --output="benchmark-%j.out"
set -euo pipefail

#--------------------------------------
# Steps to run and benchmark the code.
# This is just an example.
#--------------------------------------

echo "Running benchmark code..."
set -x
time ./helloworld |& tee timings.txt
