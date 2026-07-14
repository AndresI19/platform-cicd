#!/usr/bin/env bash
# Print the deployer ServiceAccount's kubeconfig, base64'd, for runner/.env.
#
# It points at the apiserver's NATIVE address (192.168.49.2:8443) — unroutable from the host, and
# perfectly routable from the runner, which is on minikube's docker network. That is the whole reason
# this credential is different from the one on your host.
set -euo pipefail
TOKEN="$(kubectl -n platform get secret deployer-token -o jsonpath='{.data.token}' | base64 -d)"
CA="$(kubectl -n platform get secret deployer-token -o jsonpath='{.data.ca\.crt}')"
cat <<YAML | base64 -w0
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
