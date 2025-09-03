#!/bin/bash

# Script start time for duration tracking
SCRIPT_START_TIME=$(date +%s)

# Centralized cleanup and exit function
cleanup_and_exit() {
    local exit_code=$1
    local message="$2"

    if [ $exit_code -eq 0 ]; then
        echo "✅ $message"
        echo "🎉 Upload completed successfully!"
    else
        echo "❌ $message"
        echo "❌ Upload failed with exit code $exit_code"
    fi

    # Calculate and display total execution time
    local script_end_time=$(date +%s)
    local execution_time=$((script_end_time - SCRIPT_START_TIME))
    echo "⏱️ Total execution time: ${execution_time} seconds"

    # Self-delete the script
    rm -- "$0" 2>/dev/null
    exit $exit_code
}

# Set up error handling
set -e
trap 'cleanup_and_exit 1 "Script failed due to error on line $LINENO"' ERR

echo "🚀 Starting Lambda deployment process..."
echo "⏰ Started at: $(date)"

# Check if the correct number of arguments is provided
if [ "$#" -lt 2 ] || [ "$#" -gt 3 ]; then
    echo "❌ Invalid number of arguments provided: $#"
    echo "Usage: $0 <function-name> <region> [branch-name]"
    cleanup_and_exit 1 "Invalid arguments"
fi

FUNCTION_NAME=$1
REGION=$2

echo "🔍 Validating inputs..."
echo "   Function Name: $FUNCTION_NAME"
echo "   Region: $REGION"

# Validate function name
if [ -z "$FUNCTION_NAME" ]; then
    echo "❌ Function name cannot be empty"
    cleanup_and_exit 1 "Empty function name"
fi

# Validate region
if [ -z "$REGION" ]; then
    echo "❌ Region cannot be empty"
    cleanup_and_exit 1 "Empty region"
fi

# Check AWS CLI availability
if ! command -v aws &> /dev/null; then
    echo "❌ AWS CLI is not installed or not in PATH"
    cleanup_and_exit 1 "AWS CLI not found"
fi

# Check AWS credentials
echo "🔐 Checking AWS credentials..."
if ! aws sts get-caller-identity --region "$REGION" &> /dev/null; then
    echo "❌ AWS credentials not configured or invalid for region $REGION"
    echo "🔍 Run 'aws configure' to set up credentials"
    cleanup_and_exit 1 "Invalid AWS credentials"
fi

AWS_IDENTITY=$(aws sts get-caller-identity --region "$REGION" 2>/dev/null)
AWS_ACCOUNT=$(echo "$AWS_IDENTITY" | jq -r '.Account' 2>/dev/null || echo "unknown")
AWS_USER=$(echo "$AWS_IDENTITY" | jq -r '.Arn' 2>/dev/null || echo "unknown")
echo "✅ AWS credentials valid - Account: $AWS_ACCOUNT"
echo "👤 User/Role: $AWS_USER"

# Get the branch name from the argument if provided, otherwise get the current branch name
if [ "$#" -eq 3 ]; then
    BRANCH_NAME=$3
    echo "📝 Using provided branch name: $BRANCH_NAME"
else
    if command -v git &> /dev/null; then
        BRANCH_NAME=$(git rev-parse --abbrev-ref HEAD 2>/dev/null)
        if [ $? -eq 0 ] && [ -n "$BRANCH_NAME" ]; then
            echo "📝 Detected git branch: $BRANCH_NAME"
        else
            echo "⚠️ Could not detect git branch, using 'main'"
            BRANCH_NAME="main"
        fi
    else
        echo "⚠️ Git not available, using 'main'"
        BRANCH_NAME="main"
    fi
fi

# If the branch name is "main", use "production" as the alias
if [ "$BRANCH_NAME" = "main" ]; then
    ALIAS_NAME="production"
    echo "🔄 Branch 'main' -> Alias 'production'"
else
    ALIAS_NAME=$BRANCH_NAME
    echo "🔄 Branch '$BRANCH_NAME' -> Alias '$ALIAS_NAME'"
fi

# Function to wait for Lambda function to be ready
wait_for_function_ready() {
    local function_name=$1
    local region=$2
    local max_attempts=20
    local attempt=1

    echo "⏳ Waiting for function $function_name to be ready..."

    while [ $attempt -le $max_attempts ]; do
        echo "⏳ Checking function status (attempt $attempt/$max_attempts)..."

        # Add timeout to prevent hanging
        local status=$(timeout 15 aws lambda get-function-configuration \
            --function-name "$function_name" \
            --region "$region" \
            --query 'LastUpdateStatus' \
            --output text 2>/dev/null)

        local exit_code=$?

        if [ $exit_code -eq 124 ]; then
            echo "⚠️ AWS API call timed out on attempt $attempt"
            sleep 3
            ((attempt++))
            continue
        elif [ $exit_code -ne 0 ]; then
            echo "⚠️ AWS API call failed on attempt $attempt"
            sleep 3
            ((attempt++))
            continue
        fi

        if [ "$status" = "Successful" ]; then
            echo "✅ Function is ready!"
            return 0
        elif [ "$status" = "Failed" ]; then
            echo "❌ Function update failed!"
            return 1
        else
            echo "⏳ Status: $status - waiting 3 seconds before next check..."
            sleep 3
            ((attempt++))
        fi
    done

    echo "⚠️ Timeout waiting for function to be ready"
    return 1
}

# Update the AWS Lambda function code, using the function name and region arguments
echo "📦 Updating Lambda function code..."
echo "🔧 Function: $FUNCTION_NAME, Region: $REGION, Branch: $BRANCH_NAME -> Alias: $ALIAS_NAME"

# Check if the zip file exists
if [ ! -f "dist/index.zip" ]; then
    echo "❌ Error: dist/index.zip not found!"
    echo "📁 Current directory: $(pwd)"
    echo "📂 Contents of dist directory:"
    ls -la dist/ 2>/dev/null || echo "❌ dist/ directory does not exist"
    cleanup_and_exit 1 "Missing zip file"
fi

# Show file size for context
FILE_SIZE=$(du -sh dist/index.zip | cut -f1)
echo "📦 Bundle size: $FILE_SIZE"

# Add timeout and comprehensive error handling for the update
echo "⬆️ Uploading function code to AWS Lambda..."
UPDATE_RESULT=$(timeout 120 aws lambda update-function-code \
    --function-name "$FUNCTION_NAME" \
    --zip-file fileb://dist/index.zip \
    --region "$REGION" \
    --no-cli-pager 2>&1)

UPDATE_EXIT_CODE=$?

if [ $UPDATE_EXIT_CODE -eq 124 ]; then
    echo "❌ Function code update timed out after 120 seconds"
    echo "🔍 This could indicate:"
    echo "   - Network connectivity issues"
    echo "   - AWS service slowness"
    echo "   - Bundle too large for current connection"
    cleanup_and_exit 1 "Update timeout"
elif [ $UPDATE_EXIT_CODE -ne 0 ]; then
    echo "❌ Function code update failed with exit code: $UPDATE_EXIT_CODE"
    echo "📝 AWS Error Details:"
    echo "$UPDATE_RESULT"
    echo ""
    echo "🔍 Common causes:"
    echo "   - Function name doesn't exist: $FUNCTION_NAME"
    echo "   - Insufficient permissions for region: $REGION"
    echo "   - Invalid zip file format"
    echo "   - Function is currently being updated by another process"
    echo "   - AWS service issues in region: $REGION"
    cleanup_and_exit 1 "Update failed"
else
    echo "✅ Function code updated successfully!"
    echo "📝 Update response:"
    echo "$UPDATE_RESULT" | jq . 2>/dev/null || echo "$UPDATE_RESULT"
fi

# Wait for the function to be ready before proceeding
if ! wait_for_function_ready "$FUNCTION_NAME" "$REGION"; then
    echo "❌ Failed to wait for function to be ready"
    cleanup_and_exit 1 "Function not ready"
fi

# Check if the alias already exists for the function in the specified region
echo "🔍 Checking if alias '$ALIAS_NAME' exists for function '$FUNCTION_NAME'..."
ALIAS_EXISTS=$(timeout 15 aws lambda get-alias --function-name "$FUNCTION_NAME" --name "$ALIAS_NAME" --region "$REGION" 2>&1)

if [ $? -eq 124 ]; then
    echo "❌ Timeout checking alias status"
    cleanup_and_exit 1 "Alias check timeout"
fi

# Function to publish version with retry
publish_version_with_retry() {
    local function_name=$1
    local region=$2
    local max_attempts=5
    local attempt=1

    while [ $attempt -le $max_attempts ]; do
        echo "📝 Publishing version (attempt $attempt/$max_attempts)..." >&2

        local result=$(timeout 30 aws lambda publish-version --function-name "$function_name" --region "$region" 2>&1)
        local exit_code=$?

        if [ $exit_code -eq 124 ]; then
            echo "⚠️ Publish version timed out, retrying..." >&2
            ((attempt++))
            continue
        elif [ $exit_code -ne 0 ]; then
            echo "⚠️ AWS API error on attempt $attempt" >&2
        fi

        if [[ $result == *"ResourceConflictException"* ]] && [[ $result == *"update is in progress"* ]]; then
            echo "⚠️ Function still updating, waiting before retry..." >&2
            if ! wait_for_function_ready "$function_name" "$region"; then
                echo "❌ Failed to wait for function to be ready" >&2
                return 1
            fi
            ((attempt++))
            continue
        elif [[ $result == *"Version"* ]]; then
            # Extract and return only the version number, no other output
            local version=$(echo "$result" | jq -r '.Version' 2>/dev/null)
            if [[ $version =~ ^[0-9]+$ ]]; then
                echo "$version"
                return 0
            else
                echo "❌ Invalid version format: $version" >&2
                return 1
            fi
        else
            echo "❌ Error publishing version: $result" >&2
            return 1
        fi
    done

    echo "❌ Failed to publish version after $max_attempts attempts" >&2
    return 1
}

# If the alias does not exist, create it pointing to the latest version
# Otherwise, update the existing alias to point to the latest version
if [[ $ALIAS_EXISTS == *"ResourceNotFoundException"* ]]; then
    # Get the latest version number with retry
    echo "🆕 Creating new alias..."
    LATEST_VERSION=$(publish_version_with_retry "$FUNCTION_NAME" "$REGION")
    if [ $? -ne 0 ] || [ -z "$LATEST_VERSION" ]; then
        echo "❌ Failed to publish version for new alias"
        cleanup_and_exit 1 "Failed to publish version"
    fi

    # Create a new alias for the latest version in the specified region
    echo "🏗️ Creating alias '$ALIAS_NAME' pointing to version '$LATEST_VERSION'..."
    if timeout 15 aws lambda create-alias --function-name "$FUNCTION_NAME" --name "$ALIAS_NAME" --function-version "$LATEST_VERSION" --region "$REGION"; then
        echo "✅ Created new alias '$ALIAS_NAME' for function '$FUNCTION_NAME' version '$LATEST_VERSION' in region '$REGION'"
    else
        echo "❌ Failed to create alias (timeout or error)"
        cleanup_and_exit 1 "Failed to create alias"
    fi
else
    # Update the existing alias to point to the latest version in the specified region
    echo "🔄 Updating existing alias..."
    LATEST_VERSION=$(publish_version_with_retry "$FUNCTION_NAME" "$REGION")
    if [ $? -ne 0 ] || [ -z "$LATEST_VERSION" ]; then
        echo "❌ Failed to publish version for alias update"
        cleanup_and_exit 1 "Failed to publish version"
    fi

    echo "🔄 Updating alias '$ALIAS_NAME' to point to version '$LATEST_VERSION'..."
    UPDATE_ALIAS_RESULT=$(timeout 15 aws lambda update-alias --function-name "$FUNCTION_NAME" --name "$ALIAS_NAME" --function-version "$LATEST_VERSION" --region "$REGION" 2>&1)
    UPDATE_ALIAS_EXIT_CODE=$?

    #hhehre

    if [ $UPDATE_ALIAS_EXIT_CODE -eq 0 ]; then
        echo "✅ Updated alias '$ALIAS_NAME' for function '$FUNCTION_NAME' to version '$LATEST_VERSION' in region '$REGION'"
        echo "📝 Alias update response:"
        echo "$UPDATE_ALIAS_RESULT" | jq . 2>/dev/null || echo "$UPDATE_ALIAS_RESULT"
    elif [ $UPDATE_ALIAS_EXIT_CODE -eq 124 ]; then
        echo "❌ Alias update timed out after 15 seconds"
        echo "🔍 Check AWS console to verify if update actually succeeded"
        cleanup_and_exit 1 "Alias update timeout"
    else
        echo "❌ Failed to update alias with exit code: $UPDATE_ALIAS_EXIT_CODE"
        echo "📝 AWS Error Details:"
        echo "$UPDATE_ALIAS_RESULT"
        cleanup_and_exit 1 "Failed to update alias"
    fi
fi

cleanup_and_exit 0 "Lambda deployment completed successfully"