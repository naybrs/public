#!/bin/bash

# Script start time for duration tracking
SCRIPT_START_TIME=$(date +%s)

echo "🚀 Starting Lambda deployment process..."
echo "⏰ Started at: $(date)"

# Check if the correct number of arguments is provided
if [ "$#" -lt 2 ] || [ "$#" -gt 3 ]; then
    echo "Usage: $0 <function-name> <region> [branch-name]"
    exit 1
fi

FUNCTION_NAME=$1
REGION=$2

# Get the branch name from the argument if provided, otherwise get the current branch name
if [ "$#" -eq 3 ]; then
    BRANCH_NAME=$3
else
    BRANCH_NAME=$(git rev-parse --abbrev-ref HEAD)
fi

# If the branch name is "main", use "production" as the alias
if [ "$BRANCH_NAME" = "main" ]; then
    ALIAS_NAME="production"
else
    ALIAS_NAME=$BRANCH_NAME
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

# Add timeout and better error handling for the update
if ! timeout 60 aws lambda update-function-code --function-name "$FUNCTION_NAME" --zip-file fileb://dist/index.zip --region "$REGION"; then
    echo "❌ Failed to update function code (timeout or error)"
    exit 1
fi

# Wait for the function to be ready before proceeding
if ! wait_for_function_ready "$FUNCTION_NAME" "$REGION"; then
    echo "❌ Failed to wait for function to be ready. Exiting."
    exit 1
fi

# Check if the alias already exists for the function in the specified region
echo "🔍 Checking if alias '$ALIAS_NAME' exists for function '$FUNCTION_NAME'..."
ALIAS_EXISTS=$(timeout 15 aws lambda get-alias --function-name "$FUNCTION_NAME" --name "$ALIAS_NAME" --region "$REGION" 2>&1)

if [ $? -eq 124 ]; then
    echo "❌ Timeout checking alias status"
    exit 1
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
            echo "$result" | jq -r '.Version'
            return 0
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
        exit 1
    fi

    # Create a new alias for the latest version in the specified region
    echo "🏗️ Creating alias '$ALIAS_NAME' pointing to version '$LATEST_VERSION'..."
    if timeout 15 aws lambda create-alias --function-name "$FUNCTION_NAME" --name "$ALIAS_NAME" --function-version "$LATEST_VERSION" --region "$REGION"; then
        echo "✅ Created new alias '$ALIAS_NAME' for function '$FUNCTION_NAME' version '$LATEST_VERSION' in region '$REGION'"
    else
        echo "❌ Failed to create alias (timeout or error)"
        exit 1
    fi
else
    # Update the existing alias to point to the latest version in the specified region
    echo "🔄 Updating existing alias..."
    LATEST_VERSION=$(publish_version_with_retry "$FUNCTION_NAME" "$REGION")
    if [ $? -ne 0 ] || [ -z "$LATEST_VERSION" ]; then
        echo "❌ Failed to publish version for alias update"
        exit 1
    fi

    echo "🔄 Updating alias '$ALIAS_NAME' to point to version '$LATEST_VERSION'..."
    if timeout 15 aws lambda update-alias --function-name "$FUNCTION_NAME" --name "$ALIAS_NAME" --function-version "$LATEST_VERSION" --region "$REGION"; then
        echo "✅ Updated alias '$ALIAS_NAME' for function '$FUNCTION_NAME' to version '$LATEST_VERSION' in region '$REGION'"
    else
        echo "❌ Failed to update alias (timeout or error)"
        exit 1
    fi
fi

# Calculate and display total execution time
SCRIPT_END_TIME=$(date +%s)
EXECUTION_TIME=$((SCRIPT_END_TIME - SCRIPT_START_TIME))
echo "⏱️ Total execution time: ${EXECUTION_TIME} seconds"
echo "🎉 Upload completed successfully!"

# Self-delete the script
rm -- "$0"