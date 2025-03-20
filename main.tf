terraform {
    required_providers {
        aws = {
        source  = "hashicorp/aws"
        version = "~> 3.0"
        }
    }
}
provider "aws" {
  region = "af-south-1-los-1a" 
}

# S3 bucket for raw data storage
resource "aws_s3_bucket" "raw_data_bucket" {
  bucket = "xyz-energy-raw-data-bucket"

  tags = {
    Name = "Raw Energy Data Bucket"
  }
}

resource "aws_s3_bucket_policy" "raw_data_bucket_policy" {
    bucket = aws_s3_bucket.raw_data_bucket.id

    policy = jsonencode({
        Version = "2012-10-17"
        Statement = [
            {
                Effect = "Allow"
                Principal = "*"
                Action = "s3:GetObject"
                Resource = "${aws_s3_bucket.raw_data_bucket.arn}/*"
            }
        ]
    })
}

# DynamoDB table for processed data
resource "aws_dynamodb_table" "energy_data_table" {
  name           = "EnergyConsumptionData"
  billing_mode   = "PAY_PER_REQUEST"
  hash_key       = "DeviceID"
  range_key      = "Timestamp"

  attribute {
    name = "DeviceID"
    type = "S"
  }

  attribute {
    name = "Timestamp"
    type = "S"
  }

  tags = {
    Name = "Energy Consumption Data Table"
  }
}

# Kinesis Data Stream
resource "aws_kinesis_stream" "energy_data_stream" {
  name             = "energy-consumption-stream"
  shard_count      = 1
  retention_period = 24 # Data retention in hours

  shard_level_metrics = [
    "IncomingBytes",
    "OutgoingBytes",
  ]

  tags = {
    Name = "Energy Consumption Data Stream"
  }
}

# IoT Core topic rule to route data to Kinesis
resource "aws_iot_topic_rule" "energy_rule" {
  name        = "EnergyConsumptionRule"
  description = "Route energy data to Kinesis"
  enabled     = true
  sql         = "SELECT * FROM 'energy/consumption'"
  sql_version = "2016-03-23"

  kinesis {
    stream_name = aws_kinesis_stream.energy_data_stream.name
    role_arn    = aws_iam_role.iot_kinesis_role.arn
  }
}

# IAM Role for IoT Core to write to Kinesis
resource "aws_iam_role" "iot_kinesis_role" {
  name = "IoTKinesisRole"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "iot.amazonaws.com"
        }
      }
    ]
  })
}

resource "aws_iam_role_policy" "iot_kinesis_policy" {
  name = "IoTKinesisPolicy"
  role = aws_iam_role.iot_kinesis_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = [
          "kinesis:PutRecord",
          "kinesis:PutRecords"
        ]
        Effect   = "Allow"
        Resource = aws_kinesis_stream.energy_data_stream.arn
      }
    ]
  })
}

# Lambda function to process data
resource "aws_lambda_function" "energy_processor" {
  function_name = "EnergyDataProcessor"
  handler       = "index.handler"
  runtime       = "python3.8"
  role          = aws_iam_role.lambda_exec_role.arn

  s3_bucket = "your-lambda-code-bucket" # S3 bucket for Lambda code
  s3_key    = "lambda-code.zip"        # Lambda code file

  environment {
    variables = {
      DYNAMODB_TABLE = aws_dynamodb_table.energy_data_table.name
      S3_BUCKET     = aws_s3_bucket.raw_data_bucket.id
    }
  }
}

# Lambda function for batching
resource "aws_lambda_function" "batch_processor" {
  function_name = "EnergyDataBatchProcessor"
  handler       = "batch_handler.handler"
  runtime       = "python3.8"
  role          = aws_iam_role.lambda_exec_role.arn

  s3_bucket = "your-lambda-code-bucket" # S3 bucket for Lambda code
  s3_key    = "batch-lambda-code.zip"   # Lambda code file

  environment {
    variables = {
      PROCESSOR_LAMBDA = aws_lambda_function.energy_processor.function_name
    }
  }
}

# Update Processor Lambda to handle batched data
resource "aws_lambda_function" "energy_processor" {
  function_name = "EnergyDataProcessor"
  handler       = "processor_handler.handler"
  runtime       = "python3.8"
  role          = aws_iam_role.lambda_exec_role.arn

  s3_bucket = "your-lambda-code-bucket" # Replace with your S3 bucket for Lambda code
  s3_key    = "processor-lambda-code.zip" # Replace with your Lambda code file

  environment {
    variables = {
      DYNAMODB_TABLE = aws_dynamodb_table.energy_data_table.name
      S3_BUCKET     = aws_s3_bucket.raw_data_bucket.id
    }
  }
}

# IAM Role for Lambda to access DynamoDB and S3
resource "aws_iam_role" "lambda_exec_role" {
  name = "LambdaExecutionRole"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "lambda.amazonaws.com"
        }
      }
    ]
  })
}

resource "aws_iam_role_policy" "lambda_dynamodb_policy" {
  name = "LambdaDynamoDBPolicy"
  role = aws_iam_role.lambda_exec_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = [
          "dynamodb:PutItem",
          "dynamodb:GetItem",
          "dynamodb:UpdateItem"
        ]
        Effect   = "Allow"
        Resource = aws_dynamodb_table.energy_data_table.arn
      }
    ]
  })
}

resource "aws_iam_role_policy" "lambda_s3_policy" {
  name = "LambdaS3Policy"
  role = aws_iam_role.lambda_exec_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = [
          "s3:PutObject",
          "s3:GetObject"
        ]
        Effect   = "Allow"
        Resource = "${aws_s3_bucket.raw_data_bucket.arn}/*"
      }
    ]
  })
}

# Trigger Lambda from Kinesis
resource "aws_lambda_event_source_mapping" "kinesis_lambda_trigger" {
  event_source_arn  = aws_kinesis_stream.energy_data_stream.arn
  function_name     = aws_lambda_function.energy_processor.arn
  starting_position = "LATEST"
}

# Trigger Batch Lambda from Kinesis
resource "aws_lambda_event_source_mapping" "kinesis_batch_trigger" {
  event_source_arn  = aws_kinesis_stream.energy_data_stream.arn
  function_name     = aws_lambda_function.batch_processor.arn
  starting_position = "LATEST"
}


# CloudWatch Logs for Lambda
resource "aws_cloudwatch_log_group" "lambda_log_group" {
  name = "/aws/lambda/${aws_lambda_function.energy_processor.function_name}"

  retention_in_days = 7
}

# Output the DynamoDB table name
output "dynamodb_table_name" {
  value = aws_dynamodb_table.energy_data_table.name
}
