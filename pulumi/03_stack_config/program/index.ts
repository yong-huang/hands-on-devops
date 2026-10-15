// =============================================================================
// 03 · Stack 与配置 —— 一份程序，多套环境
//
// 同一份 index.ts 要同时服务 dev 和 prod：容器名、端口、镜像、问候语全都不同。
// 这些"环境差异"不进代码，进 stack 的配置——程序只负责读。
//
//   pulumi up -s dev    按 dev 的配置执行一次（dev 自己的账本）
//   pulumi up -s prod   按 prod 的配置执行一次（prod 自己的账本）
//
// 运行入口是 ../stack_config.sh（负责建栈、写配置、跑生命周期）。
// =============================================================================
import * as pulumi from "@pulumi/pulumi";
import * as docker from "@pulumi/docker";

// 当前 stack 的名字（"dev" / "prod"）——程序知道自己正被哪个环境执行
const stack = pulumi.getStack();

// 配置读取三件套：requireNumber 类型化读数字、require 必填字符串、
// requireSecret 读加密存储的敏感值（缺任何一项都会在执行时明确报错）
const config = new pulumi.Config();
const port = config.requireNumber("port");
const image = config.require("image");
const greetingSecret = config.requireSecret("greeting");

// 同名资源逻辑名 "web"，在两个 stack 里各是一份独立身份——
// 真名按 stack 派生，两个环境互不撞名
const web = new docker.Container("web", {
    name: `pulumi03-${stack}-web`,
    image,
    ports: [{ internal: 80, external: port }],
    // secret 在部署时会解密并注入容器环境变量（at rest 全程密文，见 README）
    envs: [pulumi.interpolate`SITE_GREETING=${greetingSecret}`],
});

export const url = pulumi.interpolate`http://localhost:${port}/`;
// 导出 secret：up 输出里会显示为 [secret]，不会打明文
export const greeting = greetingSecret;
