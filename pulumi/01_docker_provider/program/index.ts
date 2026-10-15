// =============================================================================
// 01 · Docker Provider —— 程序即基础设施
//
// 与 .tf 文件最大的区别：这里是真正的 TypeScript 程序。变量、函数、类型检查、
// 依赖包……语言里的一切都可以用，Pulumi CLI 执行它并采纳其中声明的资源。
// 本实验只声明两个资源（自定义网络 + nginx 容器），把
// 「声明 → preview → up → destroy」的回路跑透；复杂度留给后面的实验。
//
// 它由 ../docker_provider.sh 驱动运行（登录本地后端、装依赖、调 pulumi），
// 也可以手动跑：cd program && pulumi preview / up / destroy
// =============================================================================
import * as pulumi from "@pulumi/pulumi";
import * as docker from "@pulumi/docker";

// 资源命名前缀。普通 TS 常量——Pulumi 程序里变量怎么用，这里就怎么用。
const appName = "pulumi01";

// 自定义网络。第一个参数 "net" 是资源在 state 里的逻辑名（进 URN），
// name 才是 docker 里的真实名字；两者分离，改名不改变资源身份。
const net = new docker.Network("net", {
    name: `${appName}-net`,
});

// nginx 容器。注意 net.name 的类型是 Output<string>——一个"创建后才知道"
// 的未来值，凡是用到它的地方都会产生一条依赖边。
// Pulumi 引擎按这张依赖图决定创建顺序：先网络、后容器。
const app = new docker.Container("app", {
    name: `${appName}-nginx`,
    image: "nginx:1.27-alpine",
    ports: [{ internal: 80, external: 28081 }],
    networksAdvanced: [{ name: net.name }],
});

// export 的值会在 up 结束时以 Outputs: 段落打印，也是栈与栈之间
// 传递数据的接口；这里先体验"程序输出变成 CLI 回执"。
export const url = pulumi.interpolate`http://localhost:28081/`;
export const containerName = app.name;
