#!/bin/bash

# Minimal, robust Lambda deployer (first-upload safe)
# - No 'set -e' so missing alias won't abort the script
# - DEBUG=1 for extra logs

DEBUG=${DEBUG:-0}
dbg() { [ "$DEBUG" = "1" ] && echo "DBG: $*"; }

SCRIPT_START_TIME=$(date +%s)

finish() {
  local code="$1"
  local msg="$2"
  local end=$(date +%s)
  local dur=$((end - SCRIPT_START_TIME))
  if [ "$code" -eq 0 ]; then
    echo "✅ $msg"
    echo "🎉 Upload completed successfully!"
  else
    echo "❌ $msg"
    echo "❌ Upload failed with exit code $code"
  fi
  echo "⏱️ Total execution time: ${dur} seconds"
  # self-delete
  rm -- "$0" 2>/dev/null || true
  exit "$code"
}

echo "🚀 Starting Lambda deployment process..."
echo "⏰ Started at: $(date)"

# ---------------- Args ----------------
if [ "$#" -lt 2 ] || [ "$#" -gt 3 ]; then
  echo "Usage: $0 <function-name> <region> [branch-name]"
  finish 1 "Invalid arguments"
fi

FUNCTION_NAME="$1"
REGION="$2"

if [ -z "$FUNCTION_NAME" ] || [ -z "$REGION" ]; then
  finish 1 "Function name and region are required"
fi

# Branch -> Alias mapping
if [ "$#" -eq 3 ]; then
  BRANCH_NAME="$3"
  echo "📝 Using provided branch name: $BRANCH_NAME"
else
  if command -v git >/dev/null 2>&1; then
    BRANCH_NAME="$(git rev-parse --abbrev-ref HEAD 2>/dev/null)"
    if [ -z "$BRANCH_NAME" ]; then
      echo "⚠️ Could not detect git branch, using 'main'"
      BRANCH_NAME="main"
    else
      echo "📝 Detected git branch: $BRANCH_NAME"
    fi
  else
    echo "⚠️ Git not available, using 'main'"
    BRANCH_NAME="main"
  fi
fi

if [ "$BRANCH_NAME" = "main" ]; then
  ALIAS_NAME="production"
  echo "🔄 Branch 'main' -> Alias 'production'"
else
  ALIAS_NAME="$BRANCH_NAME"
  echo "🔄 Branch '$BRANCH_NAME' -> Alias '$ALIAS_NAME'"
fi

# ---------------- Pre-checks ----------------
if ! command -v aws >/dev/null 2>&1; then
  finish 1 "AWS CLI not found in PATH"
fi

if [ ! -f "dist/index.zip" ]; then
  echo "📁 Current directory: $(pwd)"
  echo "📂 dist/ contents:"
  ls -la dist/ 2>/dev/null || echo "(no dist dir)"
  finish 1 "dist/index.zip not found"
fi

# Validate credentials
echo "🔐 Checking AWS credentials..."
if ! aws sts get-caller-identity --region "$REGION" >/dev/null 2>&1; then
  echo "Run 'aws configure' to set up credentials for $REGION"
  finish 1 "Invalid AWS credentials"
fi

AWS_IDENTITY="$(aws sts get-caller-identity --region "$REGION" 2>/dev/null)"
AWS_ACCOUNT="$(echo "$AWS_IDENTITY" | jq -r '.Account' 2>/dev/null || echo "unknown")"
AWS_ARN="$(echo "$AWS_IDENTITY" | jq -r '.Arn' 2>/dev/null || echo "unknown")"
echo "✅ AWS credentials valid - Account: $AWS_ACCOUNT"
echo "👤 User/Role: $AWS_ARN"

# ---------------- Update code ----------------
FILE_SIZE="$(du -sh dist/index.zip | cut -f1)"
echo "📦 Bundle size: $FILE_SIZE"
echo "⬆️ Uploading function code to AWS Lambda..."

AWS_PAGER=""
UPDATE_OUT="$(aws lambda update-function-code \
  --function-name "$FUNCTION_NAME" \
  --zip-file fileb://dist/index.zip \
  --region "$REGION" 2>&1)"
UPDATE_RC=$?

dbg "update-function-code rc=$UPDATE_RC"
dbg "update-function-code out: $UPDATE_OUT"

if [ "$UPDATE_RC" -ne 0 ]; then
  echo "📝 AWS Error:"
  echo "$UPDATE_OUT"
  finish 1 "Update-function-code failed"
fi

echo "✅ Function code updated successfully!"
echo "$UPDATE_OUT" | jq . 2>/dev/null || echo "$UPDATE_OUT"

# ---------------- Wait until ready ----------------
echo "⏳ Waiting for function $FUNCTION_NAME to be ready..."
attempt=1
max_attempts=20
while [ $attempt -le $max_attempts ]; do
  echo "⏳ Checking function status (attempt $attempt/$max_attempts)..."
  STATUS="$(aws lambda get-function-configuration \
    --function-name "$FUNCTION_NAME" \
    --region "$REGION" \
    --query 'LastUpdateStatus' \
    --output text 2>/dev/null)"
  RC=$?
  dbg "get-function-configuration rc=$RC status='$STATUS'"

  if [ "$RC" -ne 0 ]; then
    echo "⚠️ AWS get-function-configuration failed; will retry"
    sleep 3
    attempt=$((attempt+1))
    continue
  fi

  if [ "$STATUS" = "Successful" ]; then
    echo "✅ Function is ready!"
    break
  elif [ "$STATUS" = "Failed" ]; then
    finish 1 "Lambda reports LastUpdateStatus=Failed"
  else
    echo "⏳ Status: $STATUS - waiting 3 seconds..."
    sleep 3
    attempt=$((attempt+1))
  fi
done

if [ $attempt -gt $max_attempts ]; then
  finish 1 "Timeout waiting for function readiness"
fi

# ---------------- Publish version ----------------
echo "📝 Publishing version..."
PUBLISH_OUT="$(aws lambda publish-version \
  --function-name "$FUNCTION_NAME" \
  --region "$REGION" 2>&1)"
PUBLISH_RC=$?
dbg "publish-version rc=$PUBLISH_RC out: $PUBLISH_OUT"

if [ "$PUBLISH_RC" -ne 0 ]; then
  echo "📝 AWS Error:"
  echo "$PUBLISH_OUT"
  finish 1 "publish-version failed"
fi

LATEST_VERSION="$(echo "$PUBLISH_OUT" | jq -r '.Version' 2>/dev/null)"
if ! [[ "$LATEST_VERSION" =~ ^[0-9]+$ ]]; then
  echo "📝 Unexpected publish-version output:"
  echo "$PUBLISH_OUT"
  finish 1 "Could not parse published version"
fi
echo "✅ Published version $LATEST_VERSION"

# ---------------- Alias: create or update ----------------
echo "🔍 Checking alias '$ALIAS_NAME'..."
GET_ALIAS_OUT="$(aws lambda get-alias \
  --function-name "$FUNCTION_NAME" \
  --name "$ALIAS_NAME" \
  --region "$REGION" 2>&1)"
GET_ALIAS_RC=$?
dbg "get-alias rc=$GET_ALIAS_RC out: $GET_ALIAS_OUT"

if [ "$GET_ALIAS_RC" -eq 0 ]; then
  # Alias exists -> update
  echo "🔄 Alias exists; updating to version $LATEST_VERSION..."
  UPDATE_ALIAS_OUT="$(aws lambda update-alias \
    --function-name "$FUNCTION_NAME" \
    --name "$ALIAS_NAME" \
    --function-version "$LATEST_VERSION" \
    --region "$REGION" 2>&1)"
  UPDATE_ALIAS_RC=$?
  dbg "update-alias rc=$UPDATE_ALIAS_RC out: $UPDATE_ALIAS_OUT"

  if [ "$UPDATE_ALIAS_RC" -ne 0 ]; then
    echo "📝 AWS Error:"
    echo "$UPDATE_ALIAS_OUT"
    finish 1 "update-alias failed"
  fi

  echo "✅ Updated alias '$ALIAS_NAME' to version '$LATEST_VERSION'"
  echo "$UPDATE_ALIAS_OUT" | jq . 2>/dev/null || echo "$UPDATE_ALIAS_OUT"

else
  # Non-zero from get-alias: either not found or real error
  if echo "$GET_ALIAS_OUT" | grep -q "ResourceNotFoundException"; then
    echo "🆕 Alias not found; creating '$ALIAS_NAME' -> $LATEST_VERSION..."
    CREATE_ALIAS_OUT="$(aws lambda create-alias \
      --function-name "$FUNCTION_NAME" \
      --name "$ALIAS_NAME" \
      --function-version "$LATEST_VERSION" \
      --region "$REGION" 2>&1)"
    CREATE_ALIAS_RC=$?
    dbg "create-alias rc=$CREATE_ALIAS_RC out: $CREATE_ALIAS_OUT"

    if [ "$CREATE_ALIAS_RC" -ne 0 ]; then
      echo "📝 AWS Error:"
      echo "$CREATE_ALIAS_OUT"
      finish 1 "create-alias failed"
    fi

    echo "✅ Created alias '$ALIAS_NAME' for version '$LATEST_VERSION'"
    echo "$CREATE_ALIAS_OUT" | jq . 2>/dev/null || echo "$CREATE_ALIAS_OUT"
  else
    echo "📝 Unexpected error from get-alias:"
    echo "$GET_ALIAS_OUT"
    finish 1 "get-alias failed with a non-not-found error"
  fi
fi

finish 0 "Lambda deployment completed successfully"
