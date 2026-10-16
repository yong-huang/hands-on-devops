// =============================================================================
// 11 · 多 Provider 混合编排 —— 一个栈，三个世界
//
// 数据流（一次 up 按依赖图自动排序）：
//   AWS 世界     LocalStack S3 的 payload 对象（"远端配置源"）
//     ↓ Output 跨 provider 流动（payload.content 流进 ConfigMap）
//   K8s 世界     kind 集群里的 ConfigMap ← Deployment（把消息注入 Pod 环境）
//     ↓ dependsOn 显式顺序（边缘服务最后起）
//   Docker 世界  宿主上的 edge 容器（观测端）
//
// 三个 provider 各连各的世界；栈是唯一的账本——三世界的资源记在同一本账里。
// 运行入口是 ../multi_provider.sh。
// =============================================================================
import * as pulumi from "@pulumi/pulumi";
import * as docker from "@pulumi/docker";
import * as k8s from "@pulumi/kubernetes";
import * as aws from "@pulumi/aws";

const config = new pulumi.Config();
const port = config.getNumber("port") ?? 28701;

// ---- 三个 provider：各连各的世界 ----
const awsProvider = new aws.Provider("localstack", {
    region: "us-east-1",
    accessKey: "test", secretKey: "test",
    skipCredentialsValidation: true,
    skipMetadataApiCheck: true,
    skipRequestingAccountId: true,
    s3UsePathStyle: true,
    endpoints: [{ s3: "http://localhost:4566", sts: "http://localhost:4566", iam: "http://localhost:4566" }],
});
const k8sProvider = new k8s.Provider("kind", { context: "kind-pulumi-lab" });
// docker provider 不用显式声明：默认从环境（DOCKER_HOST）连接本机 daemon

// ---- ① AWS 世界：LocalStack S3 上的远端配置 ----
const bucket = new aws.s3.Bucket("payload-src", {
    bucket: "pulumi11-payload",
}, { provider: awsProvider });

const payload = new aws.s3.BucketObject("config-message", {
    bucket,
    key: "message.txt",
    content: "greetings from LocalStack S3",
    contentType: "text/plain",
}, { provider: awsProvider });

// ---- ② K8s 世界：S3 的内容流进 ConfigMap（跨 provider 的 Output 流动）----
const ns = new k8s.core.v1.Namespace("lab", {
    metadata: { name: "pulumi11-lab" },
}, { provider: k8sProvider });

const cm = new k8s.core.v1.ConfigMap("app-config", {
    metadata: { name: "app-config", namespace: "pulumi11-lab" },
    // payload.content 是 LocalStack 里那个对象的内容——Output 跨 provider 流动，
    // 引擎自动推知"先 S3、后 ConfigMap"，无需手写顺序
    // （content 是可选属性，apply 兜底空串满足 Input<string>）
    data: { message: payload.content.apply((c) => c ?? "") },
}, { provider: k8sProvider, dependsOn: [ns] });

const deploy = new k8s.apps.v1.Deployment("app", {
    metadata: { name: "app", namespace: "pulumi11-lab" },
    spec: {
        replicas: 1,
        selector: { matchLabels: { app: "web" } },
        template: {
            metadata: { labels: { app: "web" } },
            spec: {
                containers: [{
                    name: "nginx",
                    image: "nginx:1.27-alpine",
                    env: [{ name: "MESSAGE", valueFrom: {
                        configMapKeyRef: { name: "app-config", key: "message" },
                    } }],
                    ports: [{ containerPort: 80 }],
                }],
            },
        },
    },
}, { provider: k8sProvider, dependsOn: [cm] });

// ---- ③ Docker 世界：边缘观测容器，dependsOn 垫底 ----
const edge = new docker.Container("edge", {
    name: "pulumi11-edge",
    image: "nginx:1.27-alpine",
    ports: [{ internal: 80, external: port }],
}, { dependsOn: [deploy] });

export const message = payload.content;
export const edgeUrl = pulumi.interpolate`http://localhost:${port}/ (${edge.name})`;
