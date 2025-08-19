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

# Find a zip to upload
for z in dist/index.zip dist/function.zip dist/lambda.zip; do
  if [ -f "$z" ]; then ZIP_PATH="$z"; break; fi
done
: "${ZIP_PATH:?❌ No deployment zip found. Expected dist/index.zip (or function.zip/lambda.zip).}"

echo "📦 Using package: $ZIP_PATH"
echo "🛠  Function: $FUNCTION_NAME  |  Region: $REGION  |  Alias: $ALIAS_NAME"

# 1) Upload code AND publish a version in one go
echo "⬆️  Updating code and publishing version…"
UPDATE_JSON="$(AWS_PAGER="" aws lambda update-function-code \
  --function-name "$FUNCTION_NAME" \
  --zip-file "fileb://$ZIP_PATH" \
  --publish \
  --region "$REGION" \
  --output json)"
PUBLISHED_VERSION="$(printf '%s' "$UPDATE_JSON" | grep -o '"Version": *"[^"]*"' | awk -F\" '{print $4}')"
echo "📌 Published version: $PUBLISHED_VERSION"

# 2) Wait until the function is fully updated (defensive)
echo "⏳ Waiting for Lambda to finish updating…"
AWS_PAGER="" aws lambda wait function-updated \
  --function-name "$FUNCTION_NAME" \
  --region "$REGION"
echo "✅ Update completed."

# 3) Create/update alias to the newly published version
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
    --function-version "$PUBLISHED_VERSION" \
    --region "$REGION" >/dev/null
  echo "🆕 Created alias '$ALIAS_NAME' -> version $PUBLISHED_VERSION"
else
  AWS_PAGER="" aws lambda update-alias \
    --function-name "$FUNCTION_NAME" \
    --name "$ALIAS_NAME" \
    --function-version "$PUBLISHED_VERSION" \
    --region "$REGION" >/dev/null
  echo "🔁 Updated alias '$ALIAS_NAME' -> version $PUBLISHED_VERSION"
fi

# 4) Verify alias target (nice sanity check)
TARGET="$(AWS_PAGER="" aws lambda get-alias \
  --function-name "$FUNCTION_NAME" \
  --name "$ALIAS_NAME" \
  --region "$REGION" \
  --query 'FunctionVersion' \
  --output text)"
echo "🔎 Alias '$ALIAS_NAME' now points to version: $TARGET"

# Optional: self-delete (remove if you plan to commit this script)
rm -- "$0"
