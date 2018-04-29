#!/bin/bash
set -xueo pipefail

IMAGE=snoyberg/stackage:nightly
LTSPATH="$HOME/.pier/downloads/stackage/plan/lts-11.6.yaml"
PACKAGES=stackage/packages.txt

stack --docker --docker-image $IMAGE build pier -j 1
stack --docker --docker-image $IMAGE runghc stackage/list-packages.hs -- $LTSPATH \
    > $PACKAGES
time stack --docker --docker-image $IMAGE \
    exec -- pier build \
    --download-local \
    --pier-yaml=stackage/pier.yaml \
    --shake-arg=--keep-going \
    -j 1 \
    -V \
    $(cat $PACKAGES)
