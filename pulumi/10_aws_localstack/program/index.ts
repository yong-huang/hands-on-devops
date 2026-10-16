// =============================================================================
// 10 · AWS Provider —— LocalStack 上的云资源，与真 AWS 同一套写法
//
// provider 的四件事决定"连到哪、信谁"：endpoint 指向 LocalStack、假凭证、
// 跳过凭证校验、S3 走 path-style。之后声明的 S3 bucket / 对象，
// 代码与真 AWS 完全一致——换 endpoint 就是换环境。
//
// 运行入口是 ../aws_local.sh。
// =============================================================================
import * as pulumi from "@pulumi/pulumi";
import * as aws from "@pulumi/aws";

const config = new pulumi.Config();
// 对象内容走配置：update 段只改它，观察原地更新（bucket 不动）
const content = config.get("content") ?? "hello from pulumi v1";

const provider = new aws.Provider("localstack", {
    region: "us-east-1",
    accessKey: "test",                    // LocalStack 不校验凭证，但要给
    secretKey: "test",
    skipCredentialsValidation: true,      // 跳过对真 AWS 的凭证验证（否则启动就报错）
    skipMetadataApiCheck: true,           // 跳过 EC2 metadata 探测（本机没有）
    s3UsePathStyle: true,                 // LocalStack 只认 path-style（桶名进路径）
    skipRequestingAccountId: true,        // 不向 STS 查账号 ID（LocalStack 无意义）
    // endpoint 按服务覆写（7.x 的形态）：只覆写 S3 不够——provider 启动还会调
    // STS/IAM，不覆写就打到真 AWS 上报 InvalidClientTokenId
    endpoints: [{
        s3: "http://localhost:4566",
        sts: "http://localhost:4566",
        iam: "http://localhost:4566",
    }],
});

// 桶名全局唯一原则在 LocalStack 里同样生效：钉死名字便于 awslocal 交叉验证
const bucket = new aws.s3.Bucket("demo", {
    bucket: "pulumi10-demo",
}, { provider });

const hello = new aws.s3.BucketObject("hello", {
    bucket,
    key: "hello.txt",
    content,
    contentType: "text/plain",
}, { provider });

export const bucketName = bucket.bucket;
export const objectKey = hello.key;
export const objectContent = hello.content;
