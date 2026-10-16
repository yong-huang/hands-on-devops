// =============================================================================
// 08 · Output 深水区 —— 每个陷阱都可复现的最小例子
//
// 四个演示点（与 ../output_deep.sh 的 graph/parallel 段配套）：
//   ① 隐式依赖：web 引用 net.name → 账本 propertyDependencies 记下这条边
//   ② 显式依赖：second 无数据依赖，靠 dependsOn: [first] 强制后建
//   ③ apply / pulumi.all：Output 组合的正解
//   ④ 顶层取值陷阱：Output 不能当普通值用——同一份状态，两种取法两种结果
//
// 运行入口是 ../output_deep.sh。
// =============================================================================
import * as pulumi from "@pulumi/pulumi";
import * as docker from "@pulumi/docker";

const config = new pulumi.Config();
const port = config.getNumber("port") ?? 28601;

// ① 隐式依赖：net.name 是 Output<string>，被 web 引用即产生一条依赖边
const net = new docker.Network("net", { name: "pulumi08-net" });

const first = new docker.Container("first", {
    name: "pulumi08-first",
    image: "nginx:1.25-alpine",
    ports: [{ internal: 80, external: port }],
    networksAdvanced: [{ name: net.name }],
});

// ② 显式依赖：second 与 first 没有任何数据引用（不吃 Output），
//    但要求"first 之后再建"——dependsOn 把这条业务顺序写进账本的 dependencies
const second = new docker.Container("second", {
    name: "pulumi08-second",
    image: "nginx:1.25-alpine",
}, { dependsOn: [first] });

// ③ apply 组合正解：多个 Output 聚合用 pulumi.all，
//    回调参数是解包后的普通值——这里才拿得到真实的字符串
export const summary = pulumi.all([first.name, net.name]).apply(
    ([container, network]) => `${container} @ ${network}`,
);

// 同一份状态，两种取法——④ 陷阱的最小复现（id 是创建后才有的值）：
console.log(`[trap] 顶层直接取 first.id：${first.id}`);   // 拿不到值：打出来是对象描述
first.id.apply((id) => {
    pulumi.log.info(`[ok] apply 里才拿得到值：first.id=${id}`);
    return id;
});

// 嵌套 apply 的反面教材与正解对照：
first.id.apply((id) =>
    net.name.apply((n) => pulumi.log.info(`[ok] 嵌套 apply（能跑但难读）：${id} @ ${n}`)),
);
export const url = pulumi.interpolate`http://localhost:${port}/ (${first.name})`;
