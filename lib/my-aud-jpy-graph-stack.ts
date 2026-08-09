import * as cdk from 'aws-cdk-lib';
import * as dynamodb from 'aws-cdk-lib/aws-dynamodb';
import * as s3 from 'aws-cdk-lib/aws-s3';
import * as lambda from 'aws-cdk-lib/aws-lambda';
import * as events from 'aws-cdk-lib/aws-events';
import * as targets from 'aws-cdk-lib/aws-events-targets';
import { Construct } from 'constructs';

export class MyAudJpyGraphStack extends cdk.Stack {
  constructor(scope: Construct, id: string, props?: cdk.StackProps) {
    super(scope, id, props);

    const prefix = cdk.Stack.of(this).stackName.toLowerCase();

    // DynamoDB Table
    const exchangeRateTable = new dynamodb.Table(this, 'ExchangeRateTable', {
      tableName: `${prefix}-exchange-rates`,
      partitionKey: {
        name: 'currency_pair',
        type: dynamodb.AttributeType.STRING,
      },
      sortKey: {
        name: 'date',
        type: dynamodb.AttributeType.STRING,
      },
      billingMode: dynamodb.BillingMode.PAY_PER_REQUEST,
      removalPolicy: cdk.RemovalPolicy.DESTROY,
    });

    // S3 Bucket for static hosting
    const webHostingBucket = new s3.Bucket(this, 'WebHostingBucket', {
      bucketName: `${prefix}-web`,
      websiteIndexDocument: 'index.html',
      publicReadAccess: true,
      blockPublicAccess: new s3.BlockPublicAccess({
        blockPublicAcls: false,
        blockPublicPolicy: false,
        ignorePublicAcls: false,
        restrictPublicBuckets: false,
      }),
      removalPolicy: cdk.RemovalPolicy.DESTROY,
      autoDeleteObjects: true,
    });

    // Lambda Function
    const fetchRateFunction = new lambda.Function(this, 'FetchRateFunction', {
      functionName: `${prefix}-fetch-rate`,
      runtime: lambda.Runtime.RUBY_3_3,
      handler: 'lambda_function.lambda_handler',
      code: lambda.Code.fromAsset('src', {
        bundling: {
          image: lambda.Runtime.RUBY_3_3.bundlingImage,
          command: [
            'bash', '-c',
            'bundle install --path vendor/bundle && cp -r . /asset-output',
          ],
          local: {
            tryBundle(outputDir: string) {
              const { execSync } = require('child_process');
              try {
                execSync('bundle --version');
              } catch {
                return false;
              }
              execSync(
                `cd src && bundle install --path vendor/bundle && cp -r . ${outputDir}`,
                { stdio: 'inherit' },
              );
              return true;
            },
          },
        },
      }),
      timeout: cdk.Duration.seconds(30),
      memorySize: 256,
      environment: {
        DYNAMODB_TABLE_NAME: exchangeRateTable.tableName,
        S3_BUCKET_NAME: webHostingBucket.bucketName,
      },
    });

    // Grant permissions
    exchangeRateTable.grantReadWriteData(fetchRateFunction);
    webHostingBucket.grantReadWrite(fetchRateFunction);

    // EventBridge Rule - Daily at UTC 0:00 (JST 9:00)
    const dailyRule = new events.Rule(this, 'DailySchedule', {
      schedule: events.Schedule.cron({ minute: '0', hour: '0' }),
      description: '毎日UTC 0:00（JST 9:00）にAUD/JPYレートを取得',
    });
    dailyRule.addTarget(new targets.LambdaFunction(fetchRateFunction));

    // Outputs
    new cdk.CfnOutput(this, 'WebsiteURL', {
      value: webHostingBucket.bucketWebsiteUrl,
      description: 'グラフ表示ページのURL',
    });

    new cdk.CfnOutput(this, 'FetchRateFunctionArn', {
      value: fetchRateFunction.functionArn,
      description: 'Lambda関数のARN',
    });

    new cdk.CfnOutput(this, 'DynamoDBTableName', {
      value: exchangeRateTable.tableName,
      description: 'DynamoDBテーブル名',
    });
  }
}
