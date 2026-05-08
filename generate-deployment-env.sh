#!/usr/bin/env bash
# Generate per-repo .env files from resource-ids.txt + config.json after infrastructure setup.
# Optionally AES-encrypt each .env and build a zip with ciphertext + EC2 PEM for export.
#
# Usage:
#   ./generate-deployment-env.sh [--out DIR] [--password PASS | env DEPLOY_BUNDLE_PASSWORD]
#   ./generate-deployment-env.sh --no-zip          # only write plaintext .env files
#
#   GENERATE_ENV_USE_API_GATEWAY — por defecto "auto": si existe API_GATEWAY_URL en resource-ids,
#     el front usa Gateway (/backend, /ai) sin /api/v1. Pon "0" para forzar ALB aunque exista el GW.
#
# Prerequisites: bash, jq, openssl; zip optional for packaging.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/config.json"
RESOURCE_IDS_FILE="$SCRIPT_DIR/resource-ids.txt"

OUT_DIR=""
BUNDLE_PASSWORD=""
DO_ZIP="1"

usage() {
    sed -n '1,25p' "$0" | tail -n +2
    exit "${1:-0}"
}

while [ $# -gt 0 ]; do
    case "$1" in
        --out) OUT_DIR="$2"; shift 2 ;;
        --password) BUNDLE_PASSWORD="$2"; shift 2 ;;
        --no-zip) DO_ZIP="0"; shift ;;
        -h|--help) usage 0 ;;
        *) echo "Unknown option: $1" >&2; usage 1 ;;
    esac
done

if [ -z "${OUT_DIR:-}" ]; then
    OUT_DIR="$SCRIPT_DIR/deployment-export-$(date +%Y%m%d-%H%M%S)"
fi

if [ -z "${BUNDLE_PASSWORD:-}" ] && [ -n "${DEPLOY_BUNDLE_PASSWORD:-}" ]; then
    BUNDLE_PASSWORD="$DEPLOY_BUNDLE_PASSWORD"
fi

if [ "$DO_ZIP" = "1" ] && [ -z "${BUNDLE_PASSWORD:-}" ]; then
    DO_ZIP="0"
    echo "NOTE: No bundle password set (--password or DEPLOY_BUNDLE_PASSWORD). Skipping zip; plaintext .env files only." >&2
fi

if [ ! -f "$CONFIG_FILE" ]; then
    echo "ERROR: Missing $CONFIG_FILE" >&2
    exit 1
fi

if [ ! -f "$RESOURCE_IDS_FILE" ]; then
    echo "ERROR: Missing $RESOURCE_IDS_FILE — run setup-infrastructure.sh first." >&2
    exit 1
fi

if ! command -v jq &>/dev/null; then
    echo "ERROR: jq is required." >&2
    exit 1
fi

get_kv() {
    local key="$1"
    grep "^${key}=" "$RESOURCE_IDS_FILE" 2>/dev/null | tail -1 | cut -d'=' -f2- || true
}

# Emite dos palabras: sslmode JDBC (?sslmode=) y sslmode libpq/AI (DB_SSLMODE).
infer_ssl_modes() {
    local host="$1"
    if [[ "$host" =~ localhost|127\.0\.0\.1|localstack ]]; then
        echo "disable disable"
    else
        echo "require require"
    fi
}

BACKEND_DB_ID="$(jq -r '.database.backend.identifier' "$CONFIG_FILE")"
AI_DB_ID="$(jq -r '.database.ai_service.identifier' "$CONFIG_FILE")"
BACKEND_DB_NAME="$(jq -r '.database.backend.database_name // "postgres"' "$CONFIG_FILE")"
AI_DB_NAME="$(jq -r '.database.ai_service.database_name // "tourism_ai"' "$CONFIG_FILE")"
DB_USER_BE="$(jq -r '.database.backend.username' "$CONFIG_FILE")"
DB_PASS_BE="$(jq -r '.database.backend.password' "$CONFIG_FILE")"
DB_USER_AI="$(jq -r '.database.ai_service.username' "$CONFIG_FILE")"
DB_PASS_AI="$(jq -r '.database.ai_service.password' "$CONFIG_FILE")"

BACKEND_EP="$(get_kv "${BACKEND_DB_ID}_ENDPOINT")"
BACKEND_PORT="$(get_kv "${BACKEND_DB_ID}_PORT")"
AI_EP="$(get_kv "${AI_DB_ID}_ENDPOINT")"
AI_PORT="$(get_kv "${AI_DB_ID}_PORT")"

LB_DNS="$(grep '^Load Balancer DNS:' "$RESOURCE_IDS_FILE" | sed -n 's/^Load Balancer DNS:[[:space:]]*//p' | tail -1)"
if [ -z "$LB_DNS" ]; then
    LB_DNS="$(get_kv "LoadBalancerDNS")"
fi

API_GW_URL="$(get_kv "API_GATEWAY_URL")"
FRONTEND_BUCKET="$(jq -r '.storage.frontend_bucket' "$CONFIG_FILE")"
REGION="$(jq -r '.project.region' "$CONFIG_FILE")"
KEY_NAME="$(jq -r '.compute.backend.key_name' "$CONFIG_FILE")"
PEM_SRC="$SCRIPT_DIR/${KEY_NAME}.pem"

read -r JDBC_SSLMODE AI_DB_SSLMODE <<<"$(infer_ssl_modes "${BACKEND_EP:-localhost}")"
JDBC_PARAMS="?sslmode=${JDBC_SSLMODE}"

if [ -z "$BACKEND_EP" ] || [ -z "$BACKEND_PORT" ]; then
    echo "ERROR: Backend RDS endpoint/port not found in resource-ids (${BACKEND_DB_ID}_ENDPOINT / _PORT)." >&2
    exit 1
fi
if [ -z "$AI_EP" ] || [ -z "$AI_PORT" ]; then
    echo "ERROR: AI RDS endpoint/port not found in resource-ids (${AI_DB_ID}_ENDPOINT / _PORT)." >&2
    exit 1
fi

if [ -z "$LB_DNS" ]; then
    echo "WARNING: Load Balancer DNS missing — frontend URLs may be incomplete." >&2
fi

mkdir -p "$OUT_DIR"

JWT_VAL="${JWT_SECRET:-}"
if [ -z "$JWT_VAL" ]; then
    if command -v openssl &>/dev/null; then
        JWT_VAL="$(openssl rand -hex 48)"
        echo "NOTE: Generated JWT_SECRET (save this bundle securely). To pin your own, export JWT_SECRET before running." >&2
    else
        JWT_VAL="REPLACE_ME_GENERATE_STRONG_SECRET"
        echo "WARNING: openssl missing — JWT_SECRET left as placeholder." >&2
    fi
fi

GOOGLE_ID="${GOOGLE_CLIENT_ID:-}"
GOOGLE_SECRET="${GOOGLE_CLIENT_SECRET:-}"
BACKEND_PUBLIC_HTTP=""
if [ -n "$LB_DNS" ]; then
    BACKEND_PUBLIC_HTTP="http://${LB_DNS}:8080"
fi

# Frontend: API Gateway por defecto si hay API_GATEWAY_URL; si no, ALB + /api/v1.
# El cliente concatena baseURL + "/travel-plans"; con GW la base es .../prod/backend (sin /api/v1).
USE_APIGW="${GENERATE_ENV_USE_API_GATEWAY:-auto}"
case "$USE_APIGW" in
    auto|"") [ -n "$API_GW_URL" ] && USE_APIGW=1 || USE_APIGW=0 ;;
    1|true|yes) USE_APIGW=1 ;;
    *) USE_APIGW=0 ;;
esac

if [ "$USE_APIGW" = "1" ] && [ -z "$API_GW_URL" ]; then
    echo "WARNING: API Gateway elegido pero API_GATEWAY_URL vacío — usando ALB para el front." >&2
    USE_APIGW=0
fi

if [ "$USE_APIGW" = "1" ]; then
    FRONTEND_API_BASE="${API_GW_URL}/backend"
    FRONTEND_AI_BASE="${API_GW_URL}/ai"
    FRONTEND_MODE_COMMENT="API Gateway → ALB (HTTP_PROXY ANY + /backend|/ai/{proxy+}); baseURL sin /api/v1."
else
    FRONTEND_API_BASE="${BACKEND_PUBLIC_HTTP:-http://REPLACE_LB_DNS:8080}/api/v1"
    FRONTEND_AI_BASE="http://${LB_DNS:-REPLACE_LB_DNS}:8000/api/v1"
    FRONTEND_MODE_COMMENT="ALB directo :8080 / :8000 + /api/v1 (igual que localhost)."
fi

GOOGLE_REDIRECT="${GOOGLE_REDIRECT_URI:-}"
if [ -z "$GOOGLE_REDIRECT" ]; then
    if [ "$USE_APIGW" = "1" ] && [ -n "$API_GW_URL" ]; then
        GOOGLE_REDIRECT="${API_GW_URL}/backend/auth/google/callback"
    elif [ -n "$BACKEND_PUBLIC_HTTP" ]; then
        GOOGLE_REDIRECT="${BACKEND_PUBLIC_HTTP}/api/v1/auth/google/callback"
    fi
fi

cat >"$OUT_DIR/frontend.env" <<EOF
# Generated for voyager-web-client — ${FRONTEND_MODE_COMMENT}
# WebSocket (SockJS) no pasa por REST API Gateway; sigue siendo el ALB :8080.
VITE_API_BASE_URL=${FRONTEND_API_BASE}
VITE_AI_SERVICE_BASE_URL=${FRONTEND_AI_BASE}
VITE_WS_BROKER_URL=${BACKEND_PUBLIC_HTTP:-http://REPLACE_LB_DNS:8080}/api/v1/ws-chat
# OAuth del backend debe apuntar a una URL que llegue a Spring /api/v1/auth/google/callback (ALB o misma lógica vía GW).
# Bucket estático S3 website (ajusta si usas CloudFront):
# VITE_PUBLIC_SITE_URL=http://${FRONTEND_BUCKET}.s3-website-${REGION}.amazonaws.com
EOF

cat >"$OUT_DIR/backend.env" <<EOF
SPRING_PROFILES_ACTIVE=prod
DB_HOST=${BACKEND_EP}
DB_PORT=${BACKEND_PORT}
DB_NAME=${BACKEND_DB_NAME}
DB_USERNAME=${DB_USER_BE}
DB_PASSWORD=${DB_PASS_BE}
DB_URL=jdbc:postgresql://${BACKEND_EP}:${BACKEND_PORT}/${BACKEND_DB_NAME}${JDBC_PARAMS}
JWT_SECRET=${JWT_VAL}
GOOGLE_CLIENT_ID=${GOOGLE_ID:-REPLACE_ME_GOOGLE_CLIENT_ID}
GOOGLE_CLIENT_SECRET=${GOOGLE_SECRET:-REPLACE_ME_GOOGLE_CLIENT_SECRET}
GOOGLE_REDIRECT_URI=${GOOGLE_REDIRECT:-http://localhost:8080/api/v1/auth/google/callback}
EOF

cat >"$OUT_DIR/ai-service.env" <<EOF
# voyager-ai-service — DB_* construyen DATABASE_URL (postgresql+psycopg2) en runtime.
DB_HOST=${AI_EP}
DB_USERNAME=${DB_USER_AI}
DB_PASSWORD=${DB_PASS_AI}
DB_NAME=${AI_DB_NAME}
DB_PORT=${AI_PORT}
DB_SSLMODE=${AI_DB_SSLMODE}
# Opcional: fuerza URL explícita (si la defines, tiene prioridad sobre DB_* en Settings).
# DATABASE_URL=
EOF

echo "Wrote:"
echo "  $OUT_DIR/frontend.env"
echo "  $OUT_DIR/backend.env"
echo "  $OUT_DIR/ai-service.env"
if [ "$USE_APIGW" = "1" ]; then
    echo "NOTE: Frontend URLs usan API Gateway (${API_GW_URL}); OAuth en backend.env → .../backend/auth/google/callback" >&2
fi

if [ "$DO_ZIP" != "1" ]; then
    echo "Done (no zip)."
    exit 0
fi

if ! command -v openssl &>/dev/null; then
    echo "ERROR: openssl required for encryption." >&2
    exit 1
fi

if ! command -v zip &>/dev/null; then
    echo "ERROR: zip required for packaging." >&2
    exit 1
fi

STAGE="$OUT_DIR/stage-bundle"
rm -rf "$STAGE"
mkdir -p "$STAGE"

for f in frontend.env backend.env ai-service.env; do
    openssl enc -aes-256-cbc -salt -pbkdf2 -iter 10000 \
        -pass pass:"$BUNDLE_PASSWORD" \
        -in "$OUT_DIR/$f" \
        -out "$STAGE/${f}.enc"
done

README="$STAGE/README-DEPLOY-BUNDLE.txt"
cat >"$README" <<EOF
SmartTrip deployment bundle (encrypted .env + PEM)

Decrypt an env file (example backend):
  openssl enc -d -aes-256-cbc -pbkdf2 -iter 10000 \\
    -pass pass:'YOUR_PASSWORD' \\
    -in backend.env.enc -out backend.env

Files:
  frontend.env.enc   — voyager-web-client
  backend.env.enc    — voyager-backend-core
  ai-service.env.enc — voyager-ai-service
  ${KEY_NAME}.pem    — SSH key for EC2 (same password only if you encrypted PEM separately; here PEM is stored plaintext inside this zip — protect the zip file).

Generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF

if [ -f "$PEM_SRC" ]; then
    cp "$PEM_SRC" "$STAGE/${KEY_NAME}.pem"
    echo "Included EC2 key: ${KEY_NAME}.pem"
else
    echo "WARNING: PEM not found at $PEM_SRC — zip will omit key." >&2
    echo "WARNING: PEM not found at $PEM_SRC — zip omitted key." >>"$README"
fi

ZIP_NAME="$OUT_DIR/smarttrip-deployment-bundle.zip"
(
    cd "$STAGE"
    zip -q "$ZIP_NAME" ./*
)

echo "Created encrypted bundle:"
echo "  $ZIP_NAME"
echo "(Protect DEPLOY_BUNDLE_PASSWORD — it decrypts all .env.enc files.)"
