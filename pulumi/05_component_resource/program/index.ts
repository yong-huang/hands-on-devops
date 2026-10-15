// =============================================================================
// 05 · ComponentResource —— 一份组件，两套实例
//
// index.ts 只做"组装"：像调 module 一样实例化两个 WebService，
// 传入不同的端口与镜像；内部几个资源、怎么连网，调用方一概不知。
// =============================================================================
import * as pulumi from "@pulumi/pulumi";
import { WebService } from "./component";

// 两套实例：同一段组件代码，两组参数——TF 里这是两段 module 块
const alpha = new WebService("alpha", {
    port: 28401,
    image: "nginx:1.27-alpine",
});

const beta = new WebService("beta", {
    port: 28402,
    image: "nginx:1.25-alpine",
});

export const urls = [alpha.url, beta.url];
