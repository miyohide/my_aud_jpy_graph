#!/usr/bin/env node
import 'source-map-support/register';
import * as cdk from 'aws-cdk-lib';
import { MyAudJpyGraphStack } from '../lib/my-aud-jpy-graph-stack';

const app = new cdk.App();
new MyAudJpyGraphStack(app, 'MyAudJpyGraphStack', {
  env: {
    account: process.env.CDK_DEFAULT_ACCOUNT,
    region: process.env.CDK_DEFAULT_REGION,
  },
});
