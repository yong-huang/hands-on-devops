// =============================================================================
// 06 · 被测的期望态声明 —— 一份"产品代码"，两道质量门禁盯着它
//
// 单测（tests/infra.spec.ts）用 mocks 假引擎跑它，断言声明的属性；
// 策略门禁（../policy/）在 preview 时逐条资源体检，违规即拦截。
// evil=true 是故意写坏的配置（镜像 latest、丢管理标签），给拦截演示用。
//
// 运行入口是 ../policy_test.sh（test / policy / evil / clean 四段）。
// =============================================================================
import * as pulumi from "@pulumi/pulumi";
import * as docker from "@pulumi/docker";

export function defineInfra() {
    const config = new pulumi.Config();
    const evil = config.getBoolean("evil") ?? false;
    const port = config.getNumber("port") ?? 28501;

    const net = new docker.Network("net", { name: "pulumi06-net" });

    const web = new docker.Container("web", {
        name: "pulumi06-web",
        // 违规点 1：evil 时镜像用 latest（implicit floating tag，不可复现）
        image: evil ? "nginx:latest" : "nginx:1.27-alpine",
        ports: [{ internal: 80, external: port }],
        networksAdvanced: [{ name: net.name }],
        // 违规点 2：evil 时丢掉管理标签（谁管的、归哪个项目，无从追溯）
        // 注意：docker SDK 5.2.0 的 labels 是 {label, value} 数组，不是字符串 map
        labels: evil ? undefined : [{ label: "managed-by", value: "pulumi-lab" }],
    });

    return { net, web };
}
