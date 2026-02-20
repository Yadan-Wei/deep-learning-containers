#!/bin/bash
#/ Usage: ./env_setup_macos.sh
#/ Fixed version for macOS

set -ex

# Detect platform
PLATFORM=$(uname -s | tr '[:upper:]' '[:lower:]')
ARCH=$(uname -m)

# Map architecture
if [ "$ARCH" = "x86_64" ]; then
    ARCH="amd64"
elif [ "$ARCH" = "arm64" ] || [ "$ARCH" = "aarch64" ]; then
    ARCH="arm64"
fi

# The below url/version is based on EKS v1.35.0
# https://docs.aws.amazon.com/eks/latest/userguide/install-kubectl.html
KUBECTL_CLIENT="https://s3.us-west-2.amazonaws.com/amazon-eks/1.35.0/2026-01-29/bin/${PLATFORM}/${ARCH}/kubectl"
EKSCTL_CLIENT="https://github.com/eksctl-io/eksctl/releases/latest/download/eksctl_$(uname -s)_${ARCH}.tar.gz"
# https://github.com/kubernetes-sigs/aws-iam-authenticator/releases
AWS_IAM_AUTHENTICATOR="https://github.com/kubernetes-sigs/aws-iam-authenticator/releases/download/v0.7.10/aws-iam-authenticator_0.7.10_${PLATFORM}_${ARCH}"

LATEST_KUBECTL_CLIENT_VERSION=1.35

# Use local bin directory if /usr/local/bin requires sudo
if [ -w "/usr/local/bin" ]; then
    BIN_DIR="/usr/local/bin"
else
    BIN_DIR="$HOME/.local/bin"
    mkdir -p "$BIN_DIR"
    echo "Using $BIN_DIR for binaries (add to PATH if needed)"
    export PATH="$BIN_DIR:$PATH"
fi

function install_kubectl_client() {
    echo "Installing kubectl to $BIN_DIR..."
    curl --silent --location ${KUBECTL_CLIENT} -o ${BIN_DIR}/kubectl
    chmod +x ${BIN_DIR}/kubectl
}

# Check AWS credentials
echo "Checking AWS credentials..."
if ! aws sts get-caller-identity; then
    echo "ERROR: AWS credentials are invalid or expired"
    echo "Please refresh your credentials and try again"
    exit 1
fi

# install aws-iam-authenticator
echo "Installing aws-iam-authenticator..."
curl --silent --location ${AWS_IAM_AUTHENTICATOR} -o ${BIN_DIR}/aws-iam-authenticator
chmod +x ${BIN_DIR}/aws-iam-authenticator

# aws-iam-authenticator version
${BIN_DIR}/aws-iam-authenticator version

# install kubectl
if ! command -v kubectl &> /dev/null; then
    install_kubectl_client
else
    echo "kubectl already installed, checking version..."
    # check if the kubectl client version is less than required version
    if command -v jq &> /dev/null; then
        KUBECTL_VERSION=$(kubectl version --client -o json 2>/dev/null || echo '{"clientVersion":{"major":"1","minor":"0"}}')
        CURRENT_KUBECTL_MAJOR=$(echo "$KUBECTL_VERSION" | jq -r '.clientVersion.major')
        CURRENT_KUBECTL_MINOR=$(echo "$KUBECTL_VERSION" | jq -r '.clientVersion.minor' | sed 's/+$//g')
        CURRENT_KUBECTL_CLIENT_VERSION="${CURRENT_KUBECTL_MAJOR}.${CURRENT_KUBECTL_MINOR}"
        
        if command -v bc &> /dev/null; then
            if (( $(echo "$CURRENT_KUBECTL_CLIENT_VERSION < $LATEST_KUBECTL_CLIENT_VERSION" | bc -l) )); then
                echo "kubectl version $CURRENT_KUBECTL_CLIENT_VERSION is older than $LATEST_KUBECTL_CLIENT_VERSION, upgrading..."
                install_kubectl_client
            fi
        else
            echo "bc not installed, skipping version check"
        fi
    else
        echo "jq not installed, skipping version check"
    fi
fi

# kubectl version
kubectl version --client

# install eksctl
if ! command -v eksctl &> /dev/null; then
    echo "Installing eksctl..."
    curl --silent --location ${EKSCTL_CLIENT} | tar xz -C /tmp
    mv /tmp/eksctl ${BIN_DIR}/
fi

# eksctl version
eksctl version

echo ""
echo "Setup complete!"
echo "If you used $HOME/.local/bin, make sure it's in your PATH:"
echo "  export PATH=\"$HOME/.local/bin:\$PATH\""
