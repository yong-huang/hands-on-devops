// =============================================================================
// 02 · 编程语言的力量 —— 循环 / 条件 / 函数
//
// 项目 1 只用两个资源，手写就够了；站点一多，"手写"就变成复制粘贴。
// 本实验把期望态交给语言本身：数据（sites.ts）驱动循环，条件表达式分流，
// 普通函数做封装——全部是你在应用代码里每天都在用的东西。
//
// 对照的 Terraform 版本见 labs/02_tf_modules（for_each 双实例 + module 封装）。
// 运行入口是 ../language_features.sh（apply / observe / scale / fail / clean）。
// =============================================================================
import * as pulumi from "@pulumi/pulumi";
import * as docker from "@pulumi/docker";
import { WEB_SITES, Site } from "./sites";

const appName = "pulumi02";

// 所有站点共用的网络：循环外的"公共部分"只声明一次
const net = new docker.Network("net", { name: `${appName}-net` });

// 函数封装：一组资源的参数模式（镜像策略 + 命名 + 端口 + 挂网）写一次，
// 每个站点调用一次——HCL 的等价物是 module + variables，这里是普通函数。
function makeSite(site: Site): docker.Container {
    // 条件表达式：按 channel 字段分流镜像 tag。
    // TS 的三元和 HCL 的三元长得一样，区别在编译器会检查两个分支类型。
    const image =
        site.channel === "preview" ? "nginx:1.25-alpine" : "nginx:1.27-alpine";

    // 资源逻辑名由数据拼出："site-alpha" / "site-beta"……
    // 数据里加一行，这里就多一个资源——这就是"数组驱动基础设施"。
    return new docker.Container(`site-${site.name}`, {
        name: `${appName}-${site.name}`,
        image,
        ports: [{ internal: 80, external: site.port }],
        networksAdvanced: [{ name: net.name }],
    });
}

// 循环：WEB_SITES 里有多少项，就创建多少容器。
// 也可以写成 containers = WEB_SITES.map(makeSite) —— 效果相同。
const containers: docker.Container[] = [];
for (const site of WEB_SITES) {
    containers.push(makeSite(site));
}

// 输出也是"算出来的"：数组 → 每站一个 URL。
// 把数组加到 3 项，这个输出会自动多一项（第 3 个地址无需手写）。
export const urls = WEB_SITES.map(
    (site) => `http://localhost:${site.port}/`,
);
