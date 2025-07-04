# NOTE: The script will try to create the ECR repository if it doesn't exist. Please grant the necessary permissions to the IAM user or role.
# Usage:
#    cd scripts
#    bash ./push-to-ecr.sh

set -o errexit  # exit on first error
set -o nounset  # exit on using unset variables
set -o pipefail # exit on any error in a pipeline

# Define variables
TAG="latest"
ARCHS=("arm64" "amd64")
AWS_REGIONS=("us-east-1") # List of AWS region, use below liest if you don't enable ECR repository replication
# AWS_REGIONS=("us-east-1" "us-west-2" "eu-central-1" "ap-southeast-1" "ap-southeast-2" "ap-northeast-1" "eu-central-1" "eu-west-3") # List of supported AWS regions

build_and_push_images() {
    local IMAGE_NAME=$1
    local TAG=$2
    local ENABLE_MULTI_ARCH=${3:-true}  # Parameter for enabling multi-arch build, default is true
    local DOCKERFILE_PATH=${4:-"../src/Dockerfile_ecs"}  # Parameter for Dockerfile path, default is "../src/Dockerfile_ecs"

    # Build Docker image for each architecture
    if [ "$ENABLE_MULTI_ARCH" == "true" ]; then
        for ARCH in "${ARCHS[@]}"
        do
            # Build multi-architecture Docker image
            docker buildx build --platform linux/$ARCH -t $IMAGE_NAME:$TAG-$ARCH -f $DOCKERFILE_PATH --push ../src/
        done
    else
        # Build single architecture Docker image
        docker buildx build --platform linux/${ARCHS[0]} -t $IMAGE_NAME:$TAG -f $DOCKERFILE_PATH --push ../src/
    fi

    # Push Docker image to ECR for each architecture in each AWS region
    for REGION in "${AWS_REGIONS[@]}"
    do
        # Get the account ID for the current region
        ACCOUNT_ID=$(aws sts get-caller-identity --region $REGION --query Account --output text)

        # Create repository URI
        REPOSITORY_URI="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com/${IMAGE_NAME}"

        # Create ECR repository if it doesn't exist
        aws ecr create-repository --repository-name "${IMAGE_NAME}" --region $REGION || true

        # Log in to ECR
        aws ecr get-login-password --region $REGION | docker login --username AWS --password-stdin $REPOSITORY_URI

        # Push the image to ECR for each architecture
        if [ "$ENABLE_MULTI_ARCH" == "true" ]; then
            for ARCH in "${ARCHS[@]}"
            do
                # Tag the image for the current region
                docker tag $IMAGE_NAME:$TAG-$ARCH $REPOSITORY_URI:$TAG-$ARCH
                # Push the image to ECR
                docker push $REPOSITORY_URI:$TAG-$ARCH
                # Create a manifest for the image
                docker manifest create $REPOSITORY_URI:$TAG --amend $REPOSITORY_URI:$TAG-arm64 $REPOSITORY_URI:$TAG-amd64
                # Annotate the manifest with architecture information
                docker manifest annotate $REPOSITORY_URI:$TAG $REPOSITORY_URI:$TAG-arm64 --os linux --arch arm64
                docker manifest annotate $REPOSITORY_URI:$TAG $REPOSITORY_URI:$TAG-amd64 --os linux --arch amd64
            done

            # Push the manifest to ECR
            docker manifest push $REPOSITORY_URI:$TAG
        else
            # Tag the image for the current region
            docker tag $IMAGE_NAME:$TAG $REPOSITORY_URI:$TAG
            # Push the image to ECR
            docker push $REPOSITORY_URI:$TAG
        fi

        echo "Pushed $IMAGE_NAME:$TAG to $REPOSITORY_URI"
    done
}

build_and_push_images "bedrock-proxy-api" "$TAG" "false" "../src/Dockerfile"
build_and_push_images "bedrock-proxy-api-ecs" "$TAG"
