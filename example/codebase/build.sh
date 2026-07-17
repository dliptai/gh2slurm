#!/bin/bash
#SBATCH --job-name=build
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=1
#SBATCH --time=00:01:00
#SBATCH --output="build-%j.out"
set -euo pipefail

#--------------------------------------
# Steps to build the code.
# This is just a simple example.
#--------------------------------------

echo "Building code..."
make
