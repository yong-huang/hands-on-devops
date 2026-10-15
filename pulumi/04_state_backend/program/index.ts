// =============================================================================
// 04 · 状态管理 —— state 是账本，后端决定账本放在哪
//
// 本实验的主角不是资源（程序只有一个 nginx 容器），而是账本本身：
//   本地 file backend 的目录长什么样？
//   账本如何整体搬到 MinIO（S3 兼容）后端？
//   搬家后 refresh 如何检出漂移？import 如何接管手工创建的资源？
//
// 运行入口是 ../state_backend.sh（负责起 MinIO、切后端、跑生命周期）。
// =============================================================================
import * as pulumi from "@pulumi/pulumi";
import * as docker from "@pulumi/docker";

// 端口来自 stack 配置（后端实验 03 的读法）——账本搬家不改变程序
const config = new pulumi.Config();
const port = config.requireNumber("port");

const web = new docker.Container("web", {
    name: "pulumi04-web",
    image: "nginx:1.27-alpine",
    ports: [{ internal: 80, external: port }],
});

export const url = pulumi.interpolate`http://localhost:${port}/`;
