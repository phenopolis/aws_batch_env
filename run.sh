#!/bin/bash

AWS_REGION=us-east-1
export AWS_REGION
####
# Create a Docker image for the HEAD node - that would run Nextflow
####
REPOSITORY_NAME="nextflow_head"

# Create a new ECR repository as a placeholder to push the Docker image
aws ecr create-repository --repository-name ${REPOSITORY_NAME}
IMAGE_ID=$(aws ecr describe-repositories --repository-names ${REPOSITORY_NAME} \
  --output text --query 'repositories[0].[repositoryUri]' --region $AWS_REGION)
# Build the Docker image
docker build -t "${IMAGE_ID}:latest" .

# Push command to ECR
aws ecr get-login-password --region $AWS_REGION | docker login --username AWS --password-stdin
docker push "${IMAGE_ID}:latest"

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
# Setup the AWS Batch Job Queue and Compute Environment
####
VPC_ID=$(aws ec2 describe-vpcs --output text --query 'Vpcs[*].VpcId' \
  --filters Name=isDefault,Values=true --region ${AWS_REGION})
SUBNET_IDS=$(aws ec2 describe-subnets --query "Subnets[*].SubnetId" \
  --filters Name=vpc-id,Values="${VPC_ID}" --region ${AWS_REGION} \
  --output text | sed 's/\s\+/,/g')

aws cloudformation deploy --stack-name nf-head-ce-jq \
  --template-file nextflow-batch-ce-jq.template.yaml \
  --capabilities CAPABILITY_IAM --region ${AWS_REGION} \
  --parameter-overrides VpcId="${VPC_ID}" SubnetIds="${SUBNET_IDS}" BaseName="main_head"


# deploy the CloudFormation stack
# This contains the AWS Batch Job Queue, Compute Environment, and Job Definition

REPOSITORY_NAME=immday-container
IMAGE_ID=$(aws ecr describe-repositories \
  --repository-names ${REPOSITORY_NAME} --output text \
  --query 'repositories[0].[repositoryUri]' --region $AWS_REGION)
ECS_ROLE_ARN=$(aws iam get-role --role-name ecsTaskExecutionRole \
  --query 'Role.[Arn]' --output text)
NF_JOB_QUEUE=nextflow-jq
NXF_VER=22.10.8

aws cloudformation deploy --stack-name nextflow-batch-jd \
  --template-file nextflow-batch-jd.template.yaml \
  --capabilities CAPABILITY_IAM --region ${AWS_REGION} \
  --parameter-overrides NFJobQueue=${NF_JOB_QUEUE} \
  BucketNameResults="${BUCKET_NAME_RESULTS}" ImageId="${IMAGE_ID}" \
  ECSRoleArn="${ECS_ROLE_ARN}" AWSRegion=${AWS_REGION}

# See list of AWS Batch resources
aws batch describe-compute-environments --region $AWS_REGION
aws batch describe-job-queues --region $AWS_REGION
aws batch describe-job-definitions --region $AWS_REGION

# Submit a job
SUBMITTED_JOB=$(aws batch submit-job --job-name nextflow-job \
  --job-queue nextflow-jq --job-definition nextflow-demo --region $AWS_REGION)
JOB_ID=$(echo "${SUBMITTED_JOB}" | jq -r '.jobId')
aws batch describe-jobs --jobs "${JOB_ID}" --region $AWS_REGION
