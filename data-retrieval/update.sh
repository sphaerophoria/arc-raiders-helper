#!/usr/bin/env bash

set -ex

cd "$(dirname "$0")"

./update_metaforge_metadata_cache.py metadata_cache
./update_extradata.py metadata_cache extradata.json
./fetch_images.py metadata_cache ../html-root/images
./preprocess.py metadata_cache extradata.json ../html-root/preprocessed.json
