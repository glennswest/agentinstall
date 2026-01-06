#!/bin/bash
# Generate .env file with secrets

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"

if [[ -f "$ENV_FILE" ]]; then
    read -p ".env already exists. Overwrite? [y/N] " confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        echo "Aborted."
        exit 0
    fi
fi

# Generate random password
REGISTRY_PASSWORD=$(openssl rand -base64 24 | tr -d '/+=' | head -c 32)

cat > "$ENV_FILE" << EOF
# Auto-generated secrets - do not commit to git
# Run ./generate-secrets.sh to regenerate

REGISTRY_PASSWORD='${REGISTRY_PASSWORD}'
EOF

chmod 600 "$ENV_FILE"
echo "Generated $ENV_FILE with new REGISTRY_PASSWORD"
