#!/bin/bash
cd "$(dirname "$0")"
kubectl apply -f ./ingress-nginx.yaml