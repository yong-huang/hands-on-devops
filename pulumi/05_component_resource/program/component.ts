// =============================================================================
// 05 · WebService 组件 —— 对标 Terraform module
//
// 把"一组资源 + 它们的连线"封装成一个类：网络 + 容器 + 对外 url。
// 调用方像用 module 一样传参实例化，看不到内部资源；
// 组件内部改一行，所有实例一起更新（演化实验见 ../component_resource.sh evolve）。
//
// 与 TF module 的对照：
//   module "alpha" { source = "./web-service" port = 28401 image = "…" }
//   ↔  new WebService("alpha", { port: 28401, image: "…" })
// =============================================================================
import * as pulumi from "@pulumi/pulumi";
import * as docker from "@pulumi/docker";

// args 是组件的"入参"（对应 module 的变量块）：类型化、必填检查在编译期
export interface WebServiceArgs {
    port: number;                  // 宿主端口
    image: pulumi.Input<string>;   // 镜像（Input<string>：普通字符串或 Output 都能传）
}

export class WebService extends pulumi.ComponentResource {
    // outputs 是组件的"返回值"（对应 module 的 output）：registerOutputs 后可被引用
    public readonly url: pulumi.Output<string>;

    constructor(name: string, args: WebServiceArgs, opts?: pulumi.ComponentResourceOptions) {
        // 第一个参数是组件的类型标签（pkg:module:type），进 URN；
        // 子资源以 { parent: this } 挂到组件上，形成父子树（见 urns 段实测）
        super("hands-on:service:WebService", name, {}, opts);

        // 以下资源对外不可见——组件是唯一的引用边界（对标 module 的封装性）
        const net = new docker.Network(`${name}-net`, {
            name: `pulumi05-${name}-net`,
        }, { parent: this });

        const web = new docker.Container(`${name}-web`, {
            name: `pulumi05-${name}-web`,
            image: args.image,
            ports: [{ internal: 80, external: args.port }],
            networksAdvanced: [{ name: net.name }],
        }, { parent: this });

        this.url = pulumi.interpolate`http://localhost:${args.port}/ (${web.name})`;
        this.registerOutputs({ url: this.url });
    }
}
