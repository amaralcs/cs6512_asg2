#!bin/bash/
# 
#   A simple script to setup necessary AWS infrastructure for CS6512 module
#
#   Usage:
#       bash setup <s3 bucket name> <ecr repo name>
#       
#   If no bucket name or ECR repo name are provided it uses the defaults:
#       - s3 bucket: ul-crypto-prices
#       - ECR repo: anomaly_detector
#   
#   Assumptions:
#       You have the AWS CLI installed
#       There is a folder called `data` with a file `instrument_price.csv` in the current directory
#       You have a Dockerfile in the directory where this script is located
#
#   Notes:
#       The first step ran is to install jq, a package used for parsing JSON
#       The default image name is `anomaly_detector` and tagging is done manually
#           by updating the $ver variable in this script            
#

echo "Installing required package: jq"
sudo apt-get install jq

dir_name=$1
if [ -z "$dir_name" ]
then
    dir_name=ul-crypto-prices
    echo "Using default value for s3 bucket name: $dir_name"
else
    echo "Creating bucket: $dir_name"
fi

# Step 1: Setup s3 bucket with files
echo "  setting up local directory..."
mkdir "$dir_name"
cp data/instrument_price.csv "$dir_name/instrument_price.csv"

cur_bucket="$(aws s3 ls | grep $dir_name)"
if [ -z $cur_bucket ]
then
    echo "  creating s3 bucket..."
    aws s3api create-bucket --bucket $dir_name
    aws s3 sync "$dir_name" "s3://$dir_name" || exit 1
else
    echo "  bucket already exists"
fi 
rm -r $dir_name
echo ""


# Step 2: create ecr repository
repo_name=$2
if [ -z "$repo_name" ]
then
    repo_name=anomaly_detector
    echo "Using default name for ECR repo: $repo_name"
else
    echo "Creating ECR repo: $repo_name"
fi

repo_list="$(aws ecr describe-repositories | jq 'select(.repositories[])')"
if [ -z "$repo_list" ]
then
    echo "No ECR repositories were found $repo_list"
    echo "Creating $repo_name ..."
    aws ecr create-repository --repository-name $repo_name || exit 1
    echo "  success!"
else
    echo "Repository already exists, skipping creation."
fi
echo ""


# Step 3: build and deploy image
ver=v0.1
img_name=anomaly_detector
docker build . -t $img_name:$ver || exit 1

account_id="$(aws sts get-caller-identity --query "Account" --output text)"
ecr_repo="$account_id.dkr.ecr.us-east-1.amazonaws.com"
img=$ecr_repo/$img_name:$ver

echo "Pushing image to $ecr_repo"
aws ecr get-login-password --region us-east-1 | docker login -u AWS --password-stdin $ecr_repo || exit 1
docker tag $img_name:$ver $img
docker push $img || exit 1
echo "  success!"

echo "Setup complete"

# Step 4: create lambda function
role="$(aws iam get-role --role-name LabRole | jq '.Role.Arn' | sed 's/"//g')"
fun=live_anomaly_detector

fun_check="$(aws lambda get-function --function-name $fun)"
if [ -z $fun_check]
then
    echo "Creating lambda function $fun ..."
    aws lambda create-function \
        --function-name $fun \
        --package-type Image \
        --code ImageUri=$img \
        --role $role
else
    echo "Function $fun already exists, skipping creation"
fi

