#!/usr/bin/env bash
# Print the deployer ServiceAccount's kubeconfig, base64'd, for runner/.env.
#
# It points at the apiserver's NATIVE address (192.168.49.2:8443) — unroutable from the host, routable
# from the runner on minikube's docker network. That is why this credential differs from the host's.
set -Eeuo pipefail
TOKEN="$(kubectl -n platform get secret deployer-token -o jsonpath='{.data.token}' | base64 -d)"
CA="$(kubectl -n platform get secret deployer-token -o jsonpath='{.data.ca\.crt}')"
base64 -w0 <<YAML
apiVersion: v1
kind: Config
clusters:
  - name: platform
    cluster:
      server: https://192.168.49.2:8443
      certificate-authority-data: ${CA}
users:
  - name: deployer
    user:
      token: ${TOKEN}
contexts:
  - name: platform
    context: { cluster: platform, user: deployer, namespace: platform }
current-context: platform
YAML
