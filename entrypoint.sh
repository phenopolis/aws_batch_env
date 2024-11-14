#!/bin/bash
set -ex


PIPELINE_URL=${PIPELINE_URL:-https://github.com/seqeralabs/nextflow-tutorial.git}
NF_SCRIPT=${NF_SCRIPT:-main.nf}
NF_OPTS=${NF_OPTS}
NF_CONFIG=/root/.nextflow/config

cat << EOF > $NF_CONFIG
profiles {
  standard {
    process.container = 'nextflow/rnaseq-nf:s3'
    docker.enabled = true
  }

  batch {
    aws.region = "$AWS_REGION"
    process.container = 'nextflow/rnaseq-nf:s3'
    process.executor = 'awsbatch'
    process.queue = "$NF_JOB_QUEUE"
  }
}
EOF

echo "=== CONFIGURATION ==="
cat /root/.nextflow/config

if [[ -z ${AWS_REGION} ]];then
  AWS_REGION=$(curl --silent ${ECS_CONTAINER_METADATA_URI} |jq -r '.Labels["com.amazonaws.ecs.task-arn"]' |awk -F: '{print $4}')
fi

if [[ "${PIPELINE_URL}" =~ ^s3://.* ]]; then
  aws s3 cp --recursive ${PIPELINE_URL} /scratch
    else
  # Assume it is a git repository
  git clone ${PIPELINE_URL} /scratch
fi

cd /scratch
echo ">> Remove container from pipeline config if present."
sed -i -e '/process.container/d' nextflow.config

# sanitize BUCKER_NAME
BUCKET_NAME_RESULTS=$(echo ${BUCKET_NAME_RESULTS} |sed -e 's#s3://##')
BUCKET_TEMP_NAME=nextflow-batch-temp-${AWS_BATCH_JOB_ID}
aws --region ${AWS_REGION} s3 mb s3://${BUCKET_TEMP_NAME}

nextflow run ${NF_SCRIPT} -profile batch -bucket-dir s3://${BUCKET_TEMP_NAME} ${NF_OPTS} --output s3://${BUCKET_NAME_RESULTS}/${AWS_BATCH_JOB_ID}
