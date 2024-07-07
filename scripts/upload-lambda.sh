#!/bin/bash

# Check if the correct number of arguments is provided
if [ "$#" -ne 2 ]; then
    echo "Usage: $0 <function-name> <region>"
    exit 1
fi

FUNCTION_NAME=$1
REGION=$2

# Get the current branch name
BRANCH_NAME=$(git rev-parse --abbrev-ref HEAD)

# Update the AWS Lambda function code, using the function name and region arguments
AWS_PAGER="" aws lambda update-function-code --function-name $FUNCTION_NAME --zip-file fileb://dist/index.zip --region $REGION

# Check if the alias already exists for the function in the specified region
ALIAS_EXISTS=$(aws lambda get-alias --function-name $FUNCTION_NAME --name $BRANCH_NAME --region $REGION 2>&1)

# If the alias does not exist, create it pointing to the latest version
# Otherwise, update the existing alias to point to the latest version
if [[ $ALIAS_EXISTS == *"ResourceNotFoundException"* ]]; then
    # Get the latest version number
    LATEST_VERSION=$(aws lambda publish-version --function-name $FUNCTION_NAME --region $REGION | jq -r '.Version')
    # Create a new alias for the latest version in the specified region
    aws lambda create-alias --function-name $FUNCTION_NAME --name $BRANCH_NAME --function-version $LATEST_VERSION --region $REGION
    echo "Created new alias '$BRANCH_NAME' for function '$FUNCTION_NAME' version '$LATEST_VERSION' in region '$REGION'"
else
    # Update the existing alias to point to the latest version in the specified region
    LATEST_VERSION=$(aws lambda publish-version --function-name $FUNCTION_NAME --region $REGION | jq -r '.Version')
    aws lambda update-alias --function-name $FUNCTION_NAME --name $BRANCH_NAME --function-version $LATEST_VERSION --region $REGION
    echo "Updated alias '$BRANCH_NAME' for function '$FUNCTION_NAME' to version '$LATEST_VERSION' in region '$REGION'"
fi

# Self-delete the script
rm -- "$0"