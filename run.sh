#!/bin/bash

AWS_REGION=us-east-1
export AWS_REGION

####
# IAM Role
# Create a new IAM role for ECS tasks and attach the
# AmazonECSTaskExecutionRolePolicy policy to it.
####
aws iam create-role \
  --role-name ecsTaskExecutionRole \
  --assume-role-policy-document file://ecs-tasks-trust-policy.json

aws iam attach-role-policy \
  --role-name ecsTaskExecutionRole \
  --policy-arn arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy

####
# ONLY NEEDED IF YOU ARE USING SPOT INSTANCES
#
# # Create another role for AWS Batch to create the Spot Fleet
# aws iam create-service-linked-role --aws-service-name spotfleet.amazonaws.com


####
# Setup the AWS Batch Job Queue and Compute Environment
####
VPC_ID=$(aws ec2 describe-vpcs --output text --query 'Vpcs[*].VpcId' \
  --filters Name=isDefault,Values=true --region ${AWS_REGION})
SUBNET_IDS=$(aws ec2 describe-subnets --query "Subnets[*].SubnetId" \
  --filters Name=vpc-id,Values="${VPC_ID}" --region ${AWS_REGION} \
  --output text | sed 's/\s\+/,/g')

EC2_SPOT_ROLE=$(aws iam get-role --role-name AWSServiceRoleForEC2SpotFleet | jq -r '.Role.Arn')
BATCH_BASE_NAME="nf-main-head"

echo "VPC_ID: ${VPC_ID}"
echo "SUBNET_IDS: ${SUBNET_IDS}"
echo "EC2_SPOT_ROLE: ${EC2_SPOT_ROLE}"

SSH_KEY_NAME="${BATCH_BASE_NAME}-key"
aws ec2 create-key-pair --key-name "${SSH_KEY_NAME}" --region ${AWS_REGION} \
  --query 'KeyMaterial' --output text > "${BATCH_BASE_NAME}.pem"

aws cloudformation deploy --stack-name "nf-${BATCH_BASE_NAME}-ce-jq" \
  --template-file nextflow-batch-ce-jq.template.yaml \
  --capabilities CAPABILITY_IAM --region ${AWS_REGION} \
  --parameter-overrides VpcId="${VPC_ID}" SubnetIds="${SUBNET_IDS}" \
  BaseName="${BATCH_BASE_NAME}" SshKeyName="${SSH_KEY_NAME}"

####
# Setup the AWS Batch Job Definition for the Nextflow Head Node
####

# Create a Docker image for the HEAD node - that would run Nextflow
REPOSITORY_NAME="nextflow_head"
# Create a new ECR repository as a placeholder to push the Docker image
aws ecr create-repository --repository-name ${REPOSITORY_NAME}
IMAGE_ID=$(aws ecr describe-repositories --repository-names ${REPOSITORY_NAME} \
  --output text --query 'repositories[0].[repositoryUri]' --region $AWS_REGION)
echo "IMAGE_ID: ${IMAGE_ID}"

docker build -t "${IMAGE_ID}:latest" nf_head_docker

# Push command to ECR
aws ecr get-login-password --region $AWS_REGION | \
  docker login --username AWS --password-stdin "${IMAGE_ID}"
docker push "${IMAGE_ID}:latest"

ECS_ROLE_ARN=$(aws iam get-role --role-name ecsTaskExecutionRole \
  --query 'Role.[Arn]' --output text)
echo "ECS_ROLE_ARN: ${ECS_ROLE_ARN}"
# NF Job Queue to submit Nextflow jobs to.
NF_JOB_QUEUE=${BATCH_BASE_NAME}-job-queue

aws cloudformation deploy --stack-name nf-${BATCH_BASE_NAME}-jd \
  --template-file nextflow-batch-jd.template.yaml \
  --capabilities CAPABILITY_IAM --region ${AWS_REGION} \
  --parameter-overrides NFJobQueue=${NF_JOB_QUEUE} ImageId="${IMAGE_ID}" \
  ECSRoleArn="${ECS_ROLE_ARN}" AWSRegion=${AWS_REGION} BaseName="${BATCH_BASE_NAME}"

####
#
####

# Submit a job
SUBMITTED_JOB=$(aws batch submit-job --job-name nextflow-job \
  --job-queue "${BATCH_BASE_NAME}-job-queue" \
  --job-definition "${BATCH_BASE_NAME}-job-definition" \
  --region $AWS_REGION --cli-input-json file://sentieon.json)


JOB_ID=$(echo "${SUBMITTED_JOB}" | jq -r '.jobId')
aws batch describe-jobs --jobs "${JOB_ID}" --region $AWS_REGION
