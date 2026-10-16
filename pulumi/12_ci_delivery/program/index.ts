// =============================================================================
// 12 · 交付闭环 —— 被门禁保护的期望态（与 10 号实验同一形态）
//
// 内容走配置：PR 改配置 → preview --diff 门禁展示变更 → up 部署 →
// --expect-no-changes 漂移门禁复核。CI 里跑的就是这段程序，
// 本地（../ci_delivery.sh gate）跑的也是它——门禁语义先本地验证，再进 act。
// =============================================================================
import * as pulumi from "@pulumi/pulumi";
import * as aws from "@pulumi/aws";

const config = new pulumi.Config();
const content = config.get("content") ?? "v1";

const provider = new aws.Provider("localstack", {
    region: "us-east-1",
    accessKey: "test", secretKey: "test",
    skipCredentialsValidation: true,
    skipMetadataApiCheck: true,
    skipRequestingAccountId: true,
    s3UsePathStyle: true,
    endpoints: [{
        s3: "http://localhost:4566",
        sts: "http://localhost:4566",
        iam: "http://localhost:4566",
    }],
});

// 桶名全局唯一：按栈名派生——dev 与 ci 两个栈各建各的桶，互不撞名
const stack = pulumi.getStack();
const bucket = new aws.s3.Bucket("app", {
    bucket: `pulumi12-app-${stack}`,
}, { provider });

const hello = new aws.s3.BucketObject("hello", {
    bucket,
    key: "release.txt",
    content,
    contentType: "text/plain",
}, { provider });

export const bucketName = bucket.bucket;
export const releaseContent = hello.content;
