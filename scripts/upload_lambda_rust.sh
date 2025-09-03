#!/bin/bash

# Rust Lambda Upload Script
# This is the Rust equivalent of your Node.js upload_lambda.sh script

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

echo "Building Rust Lambda function..."
echo "Function: $FUNCTION_NAME"
echo "Region: $REGION"
echo "Branch: $BRANCH_NAME"
echo "Alias: $ALIAS_NAME"

# Build the Rust Lambda function for AWS Lambda (x86_64-unknown-linux-musl target)
echo "Compiling Rust code for Lambda runtime..."
cargo build --release --target x86_64-unknown-linux-musl

# Check if build was successful
if [ $? -ne 0 ]; then
    echo "Error: Rust build failed"
    exit 1
fi

# Create distribution directory
mkdir -p dist
rm -f dist/bootstrap.zip

# Copy the binary to the dist directory and rename it to 'bootstrap' (required by Lambda)
cp target/x86_64-unknown-linux-musl/release/bootstrap dist/bootstrap

# Create the deployment zip file
cd dist
zip bootstrap.zip bootstrap
cd ..

echo "Created deployment package: dist/bootstrap.zip"

# Update the AWS Lambda function code
echo "Updating Lambda function code..."
AWS_PAGER="" aws lambda update-function-code \
    --function-name "$FUNCTION_NAME" \
    --zip-file fileb://dist/bootstrap.zip \
    --region "$REGION"

# Check if the alias already exists for the function in the specified region
ALIAS_EXISTS=$(aws lambda get-alias \
    --function-name "$FUNCTION_NAME" \
    --name "$ALIAS_NAME" \
    --region "$REGION" 2>&1)

# If the alias does not exist, create it pointing to the latest version
# Otherwise, update the existing alias to point to the latest version
if [[ $ALIAS_EXISTS == *"ResourceNotFoundException"* ]]; then
    # Get the latest version number
    LATEST_VERSION=$(aws lambda publish-version \
        --function-name "$FUNCTION_NAME" \
        --region "$REGION" | jq -r '.Version')

    # Create a new alias for the latest version in the specified region
    aws lambda create-alias \
        --function-name "$FUNCTION_NAME" \
        --name "$ALIAS_NAME" \
        --function-version "$LATEST_VERSION" \
        --region "$REGION"

    echo "Created new alias '$ALIAS_NAME' for function '$FUNCTION_NAME' version '$LATEST_VERSION' in region '$REGION'"
else
    # Update the existing alias to point to the latest version in the specified region
    LATEST_VERSION=$(aws lambda publish-version \
        --function-name "$FUNCTION_NAME" \
        --region "$REGION" | jq -r '.Version')

    aws lambda update-alias \
        --function-name "$FUNCTION_NAME" \
        --name "$ALIAS_NAME" \
        --function-version "$LATEST_VERSION" \
        --region "$REGION"

    echo "Updated alias '$ALIAS_NAME' for function '$FUNCTION_NAME' to version '$LATEST_VERSION' in region '$REGION'"
fi

echo "Lambda function deployment completed successfully!"

# Self-delete the script
rm -- "$0"
