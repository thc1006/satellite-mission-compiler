#!/usr/bin/env bash
set -euo pipefail

: "${ARGO_VERSION:=v4.0.1}"

kubectl create namespace argo --dry-run=client -o yaml | kubectl apply -f -
kubectl apply --server-side -n argo -f "https://github.com/argoproj/argo-workflows/releases/download/${ARGO_VERSION}/install.yaml"

echo "[INFO] Argo Workflows ${ARGO_VERSION} manifest applied."
