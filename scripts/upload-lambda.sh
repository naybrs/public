#!/usr/bin/env bash
set -euo pipefail

# Usage: ./upload_lambda.sh <function-name> <region> [branch-name]

if [ "$#" -lt 2 ] || [ "$#" -gt 3 ]; then
  echo "Usage: $0 <function-name> <region> [branch-name]"
  exit 1
fi

FUNCTION_NAME="$1"
REGION="$2"

# Determine branch/alias
if [ "$#" -eq 3 ]; then
  BRANCH_NAME="$3"
else
  BRANCH_NAME="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo 'main')"
fi
if [ "$BRANCH_NAME" = "main" ]; then
  ALIAS_NAME="production"
else
  ALIAS_NAME="$BRANCH_NAME"
fi

# Find a zip to upload (Python first, then Node, then generic)
ZIP_CANDIDATES=("dist/function.zip" "dist/index.zip" "dist/lambda.zip")
ZIP_PATH=""
for z in "${ZIP_CANDIDATES[@]}"; do
  if [ -f "$z" ]; then
    ZIP_PATH="$z"
    break
  fi
done

if [ -z "$ZIP_PATH" ]; then
  echo "❌ No deployment zip found. Expected one of: ${ZIP_CANDIDATES[*]}"
  exit 1
fi

echo "📦 Using package: $ZIP_PATH"
echo "🛠  Function: $FUNCTION_NAME  |  Region: $REGION  |  Alias: $ALIAS_NAME"

# Upload code
AWS_PAGER="" aws lambda update-function-code \
  --function-name "$FUNCTION_NAME" \
  --zip-file "fileb://$ZIP_PATH" \
  --region "$REGION" >/dev/null
echo "✅ Code uploaded."

# Publish a new version; avoid jq by using --query
LATEST_VERSION="$(AWS_PAGER="" aws lambda publish-version \
  --function-name "$FUNCTION_NAME" \
  --region "$REGION" \
  --query 'Version' \
  --output text)"

echo "📌 Latest published version: $LATEST_VERSION"

# Create or update alias
set +e
AWS_PAGER="" aws lambda get-alias \
  --function-name "$FUNCTION_NAME" \
  --name "$ALIAS_NAME" \
  --region "$REGION" >/dev/null 2>&1
ALIAS_STATUS=$?
set -e

if [ $ALIAS_STATUS -ne 0 ]; then
  AWS_PAGER="" aws lambda create-alias \
    --function-name "$FUNCTION_NAME" \
    --name "$ALIAS_NAME" \
    --function-version "$LATEST_VERSION" \
    --region "$REGION" >/dev/null
  echo "🆕 Created alias '$ALIAS_NAME' -> version $LATEST_VERSION"
else
  AWS_PAGER="" aws lambda update-alias \
    --function-name "$FUNCTION_NAME" \
    --name "$ALIAS_NAME" \
    --function-version "$LATEST_VERSION" \
    --region "$REGION" >/dev/null
  echo "🔁 Updated alias '$ALIAS_NAME' -> version $LATEST_VERSION"
fi

# Self-delete (optional; keep if you curl it fresh each time)
rm -- "$0"
