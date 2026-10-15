// =============================================================================
// 06 · mocks 单测 —— 假引擎上的期望态断言
//
// setMocks 拦下引擎对真实 Docker API 的一切调用：资源"登记"即返回 mock id 与
// 传入的 inputs。于是测试只验证一件事——程序声明的期望态对不对，秒级、离线、
// 不需要 Docker 在跑。pulumi.unwrap 把 Output（"未来值"）解成普通值供断言。
// =============================================================================
import * as pulumi from "@pulumi/pulumi";
import { describe, it } from "mocha";
import assert from "node:assert";
import { defineInfra } from "../infra";

pulumi.runtime.setMocks({
    newResource: async (args) => ({
        id: `${args.name}-mock-id`,
        state: args.inputs,          // 把程序传入的属性原样当"已实现状态"回填
    }),
    call: async (args) => ({ outputs: args.inputs, state: args.inputs }),
});

// Output 是"创建后才有值的未来值"：apply 注册回调，包成 Promise 供 await 解包
const value = <T>(o: pulumi.Input<T>): Promise<T> =>
    new Promise<T>((resolve) => pulumi.output(o).apply((v) => resolve(v as unknown as T)));

const infra = defineInfra();

describe("web 容器的期望态（mocks 单测）", () => {
    it("镜像带明确的非 latest 标签", async () => {
        const image = await value(infra.web.image);
        assert.match(image, /:[^/]+$/, `镜像 ${image} 缺少标签`);
        assert.ok(!image.endsWith(":latest"), "禁止 latest");
    });

    it("发布在 28501 端口", async () => {
        const ports = (await value(infra.web.ports)) ?? [];
        assert.equal(ports[0]?.internal, 80);
        assert.equal(ports[0]?.external, 28501);
    });

    it("带 managed-by 管理标签", async () => {
        const labels = (await value(infra.web.labels)) ?? [];
        const found = labels.find((l) => l.label === "managed-by");
        assert.equal(found?.value, "pulumi-lab");
    });

    it("URN 指向 docker 容器类型（不是别的资源顶名）", async () => {
        const urn = await value(infra.web.urn);
        assert.ok(urn.includes("docker:index/container:Container"), urn);
    });
});
