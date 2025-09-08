#!/bin/bash

# Lambda deploy script (first-upload safe) with FULL AWS logs printed.
# Usage: ./upload_lambda.sh <function-name> <region> [branch-name]
# Example: ./upload_lambda.sh naybrs-store-customer-public-reviews us-west-1

# ---------------- General setup ----------------
SCRIPT_START_TIME=$(date +%s)
DEBUG=${DEBUG:-0}     # set DEBUG=1 to also print extra local debug lines

dbg() { [ "$DEBUG" = "1" ] && echo "DBG: $*"; }

finish() {
  local code="$1"
  local msg="$2"
  local end="$(date +%s)"
  local dur=$((end - SCRIPT_START_TIME))
  if [ "$code" -eq 0 ]; then
    echo "✅ $msg"
    echo "🎉 Upload completed successfully!"
  else
    echo "❌ $msg"
    echo "❌ Upload failed with exit code $code"
  fi
  echo "⏱️ Total execution time: ${dur} seconds"

  # Self-delete best-effort
  rm -- "$0" 2>/dev/null || true
  exit "$code"
}

echo "🚀 Starting Lambda deployment process..."
echo "⏰ Started at: $(date)"

# ---------------- Arg parsing ----------------
if [ "$#" -lt 2 ] || [ "$#" -gt 3 ]; then
  echo "Usage: $0 <function-name> <region> [branch-name]"
  finish 1 "Invalid arguments"
fi

FUNCTION_NAME="$1"
REGION="$2"

if [ -z "$FUNCTION_NAME" ] || [ -z "$REGION" ]; then
  finish 1 "Function name and region are required"
fi

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

echo "🔐 Checking AWS credentials..."
AWS_ID_LOG="$(mktemp)"
AWS_ID_OUT="$(aws sts get-caller-identity --region "$REGION" 2>&1 | tee "$AWS_ID_LOG")"
AWS_ID_RC=$?
echo "AWS sts get-caller-identity output:"
cat "$AWS_ID_LOG"
rm -f "$AWS_ID_LOG"

if [ "$AWS_ID_RC" -ne 0 ]; then
  echo "Run 'aws configure' to set up credentials for $REGION"
  finish 1 "Invalid AWS credentials"
fi

AWS_ACCOUNT="$(echo "$AWS_ID_OUT" | jq -r '.Account' 2>/dev/null || echo "unknown")"
AWS_ARN="$(echo "$AWS_ID_OUT" | jq -r '.Arn' 2>/dev/null || echo "unknown")"
echo "✅ AWS credentials valid - Account: $AWS_ACCOUNT"
echo "👤 User/Role: $AWS_ARN"

# ---------------- Update function code ----------------
FILE_SIZE="$(du -sh dist/index.zip | cut -f1)"
echo "📦 Bundle size: $FILE_SIZE"
echo "⬆️ Uploading function code to AWS Lambda..."

UPDATE_LOG="$(mktemp)"
UPDATE_OUT="$(aws lambda update-function-code \
  --function-name "$FUNCTION_NAME" \
  --zip-file fileb://dist/index.zip \
  --region "$REGION" 2>&1 | tee "$UPDATE_LOG")"
UPDATE_RC=$?

echo "AWS lambda update-function-code output:"
cat "$UPDATE_LOG"
rm -f "$UPDATE_LOG"

if [ "$UPDATE_RC" -ne 0 ]; then
  finish 1 "update-function-code failed"
fi
echo "✅ Function code updated successfully!"

# ---------------- Wait for readiness ----------------
echo "⏳ Waiting for function $FUNCTION_NAME to be ready..."
attempt=1
max_attempts=20
while [ $attempt -le $max_attempts ]; do
  echo "⏳ Checking function status (attempt $attempt/$max_attempts)..."
  STATUS_LOG="$(mktemp)"
  STATUS_OUT="$(aws lambda get-function-configuration \
    --function-name "$FUNCTION_NAME" \
    --region "$REGION" \
    --query 'LastUpdateStatus' \
    --output text 2>&1 | tee "$STATUS_LOG")"
  STATUS_RC=$?

  echo "AWS lambda get-function-configuration output:"
  cat "$STATUS_LOG"
  rm -f "$STATUS_LOG"

  dbg "get-function-configuration rc=$STATUS_RC parsed_status='$STATUS_OUT'"

  if [ "$STATUS_RC" -ne 0 ]; then
    echo "⚠️ get-function-configuration failed; retrying..."
    sleep 3
    attempt=$((attempt+1))
    continue
  fi

  if [ "$STATUS_OUT" = "Successful" ]; then
    echo "✅ Function is ready!"
    break
  elif [ "$STATUS_OUT" = "Failed" ]; then
    finish 1 "Lambda reports LastUpdateStatus=Failed"
  else
    echo "⏳ Status: $STATUS_OUT - waiting 3 seconds..."
    sleep 3
    attempt=$((attempt+1))
  fi
done

if [ $attempt -gt $max_attempts ]; then
  finish 1 "Timeout waiting for function readiness"
fi

# ---------------- Publish version ----------------
echo "📝 Publishing version..."
PUBLISH_LOG="$(mktemp)"
PUBLISH_OUT="$(aws lambda publish-version \
  --function-name "$FUNCTION_NAME" \
  --region "$REGION" 2>&1 | tee "$PUBLISH_LOG")"
PUBLISH_RC=$?

echo "AWS lambda publish-version output:"
cat "$PUBLISH_LOG"
rm -f "$PUBLISH_LOG"

if [ "$PUBLISH_RC" -ne 0 ]; then
  finish 1 "publish-version failed"
fi

LATEST_VERSION="$(echo "$PUBLISH_OUT" | jq -r '.Version' 2>/dev/null)"
if ! [[ "$LATEST_VERSION" =~ ^[0-9]+$ ]]; then
  echo "📝 Unexpected publish-version output (could not parse Version):"
  echo "$PUBLISH_OUT"
  finish 1 "Could not parse published version"
fi
echo "✅ Published version $LATEST_VERSION"

# ---------------- Alias: create or update ----------------
echo "🔍 Checking if alias '$ALIAS_NAME' exists for function '$FUNCTION_NAME'..."

GET_ALIAS_LOG="$(mktemp)"
GET_ALIAS_OUT="$(aws lambda get-alias \
  --function-name "$FUNCTION_NAME" \
  --name "$ALIAS_NAME" \
  --region "$REGION" 2>&1 | tee "$GET_ALIAS_LOG")"
GET_ALIAS_RC=$?

echo "AWS lambda get-alias output:"
cat "$GET_ALIAS_LOG"
rm -f "$GET_ALIAS_LOG"

if [ "$GET_ALIAS_RC" -eq 0 ]; then
  # Alias exists -> update
  echo "🔄 Alias exists; updating to version $LATEST_VERSION..."
  UPDATE_ALIAS_LOG="$(mktemp)"
  UPDATE_ALIAS_OUT="$(aws lambda update-alias \
    --function-name "$FUNCTION_NAME" \
    --name "$ALIAS_NAME" \
    --function-version "$LATEST_VERSION" \
    --region "$REGION" 2>&1 | tee "$UPDATE_ALIAS_LOG")"
  UPDATE_ALIAS_RC=$?

  echo "AWS lambda update-alias output:"
  cat "$UPDATE_ALIAS_LOG"
  rm -f "$UPDATE_ALIAS_LOG"

  if [ "$UPDATE_ALIAS_RC" -ne 0 ]; then
    finish 1 "update-alias failed"
  fi

  echo "✅ Updated alias '$ALIAS_NAME' to version '$LATEST_VERSION'"

else
  # Non-zero from get-alias: either not found or real error
  if echo "$GET_ALIAS_OUT" | grep -q "ResourceNotFoundException"; then
    echo "🆕 Alias not found; creating '$ALIAS_NAME' -> $LATEST_VERSION..."
    CREATE_ALIAS_LOG="$(mktemp)"
    CREATE_ALIAS_OUT="$(aws lambda create-alias \
      --function-name "$FUNCTION_NAME" \
      --name "$ALIAS_NAME" \
      --function-version "$LATEST_VERSION" \
      --region "$REGION" 2>&1 | tee "$CREATE_ALIAS_LOG")"
    CREATE_ALIAS_RC=$?

    echo "AWS lambda create-alias output:"
    cat "$CREATE_ALIAS_LOG"
    rm -f "$CREATE_ALIAS_LOG"

    if [ "$CREATE_ALIAS_RC" -ne 0 ]; then
      finish 1 "create-alias failed"
    fi

    echo "✅ Created alias '$ALIAS_NAME' for version '$LATEST_VERSION'"
  else
    echo "📝 get-alias returned an unexpected error (not a NotFound):"
    echo "$GET_ALIAS_OUT"
    finish 1 "get-alias failed with a non-not-found error"
  fi
fi

finish 0 "Lambda deployment completed successfully"
