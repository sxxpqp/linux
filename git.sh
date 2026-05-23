#!/bin/bash
set -e

msg="${1:-update}"

git add .
git commit -m "$msg"
git push
