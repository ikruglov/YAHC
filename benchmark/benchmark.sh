#!/bin/sh

ulimit -n 65536
./benchmark.pl $*
