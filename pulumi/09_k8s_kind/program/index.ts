// =============================================================================
// 09 · Kubernetes Provider —— kind 集群上的期望态
//
// 与 Docker provider 同一个模型：程序声明期望态，引擎对账收敛——
// 只是这次对接的 API 换成了 Kubernetes（本机 kind 集群，context 专用）。
// 声明三件资源：Namespace + Deployment（2 副本）+ Service；
// 镜像 tag 走配置（rollout 演示：换 tag 再 up = 滚动升级）。
//
// 运行入口是 ../k8s_kind.sh。
// =============================================================================
import * as pulumi from "@pulumi/pulumi";
import * as k8s from "@pulumi/kubernetes";

const config = new pulumi.Config();
// 镜像 tag 是唯一走配置的参数：rollout 段只改它，触发滚动升级
const imageTag = config.get("imageTag") ?? "1.27";

// provider 显式指定 kubeconfig context：只管本实验的专用集群，不碰其他集群
const provider = new k8s.Provider("kind", { context: "kind-pulumi-lab" });

const nsName = "pulumi09-lab";
const labels = { app: "web" };

const ns = new k8s.core.v1.Namespace("lab", {
    metadata: { name: nsName },
}, { provider });

const deploy = new k8s.apps.v1.Deployment("web", {
    metadata: { name: "web", namespace: nsName },
    spec: {
        replicas: 2,
        selector: { matchLabels: labels },
        template: {
            metadata: { labels },
            spec: {
                containers: [{
                    name: "nginx",
                    image: `nginx:${imageTag}-alpine`,
                    ports: [{ containerPort: 80 }],
                }],
            },
        },
    },
}, { provider, dependsOn: [ns] });

const svc = new k8s.core.v1.Service("web-svc", {
    metadata: { name: "web", namespace: nsName },
    spec: {
        selector: labels,
        ports: [{ port: 80, targetPort: 80 }],
    },
}, { provider, dependsOn: [ns] });

export const deploymentName = deploy.metadata.name;
export const serviceName = svc.metadata.name;
export const image = pulumi.interpolate`nginx:${imageTag}-alpine`;
