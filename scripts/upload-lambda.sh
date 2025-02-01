#!/bin/bash

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

# Update the AWS Lambda function code, using the function name and region arguments
AWS_PAGER="" aws lambda update-function-code --function-name "$FUNCTION_NAME" --zip-file fileb://dist/index.zip --region "$REGION"

# Check if the alias already exists for the function in the specified region
ALIAS_EXISTS=$(aws lambda get-alias --function-name "$FUNCTION_NAME" --name "$ALIAS_NAME" --region "$REGION" 2>&1)

# If the alias does not exist, create it pointing to the latest version
# Otherwise, update the existing alias to point to the latest version
if [[ $ALIAS_EXISTS == *"ResourceNotFoundException"* ]]; then
    # Get the latest version number
    LATEST_VERSION=$(aws lambda publish-version --function-name "$FUNCTION_NAME" --region "$REGION" | jq -r '.Version')
    # Create a new alias for the latest version in the specified region
    aws lambda create-alias --function-name "$FUNCTION_NAME" --name "$ALIAS_NAME" --function-version "$LATEST_VERSION" --region "$REGION"
    echo "Created new alias '$ALIAS_NAME' for function '$FUNCTION_NAME' version '$LATEST_VERSION' in region '$REGION'"
else
    # Update the existing alias to point to the latest version in the specified region
    LATEST_VERSION=$(aws lambda publish-version --function-name "$FUNCTION_NAME" --region "$REGION" | jq -r '.Version')
    aws lambda update-alias --function-name "$FUNCTION_NAME" --name "$ALIAS_NAME" --function-version "$LATEST_VERSION" --region "$REGION"
    echo "Updated alias '$ALIAS_NAME' for function '$FUNCTION_NAME' to version '$LATEST_VERSION' in region '$REGION'"
fi

# Self-delete the script
rm -- "$0"