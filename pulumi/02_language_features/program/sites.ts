// =============================================================================
// sites.ts —— 站点清单（数据与程序分离）
//
// 这是"期望建几个站、每个站什么参数"的唯一数据源。
// 想扩容：往数组里加一项再 up——Pulumi 只创建/删除差集，已有的不动。
// （scale 段的演示就是把这个文件换成 3 站点版本再跑一遍。）
// =============================================================================

// 用接口给数据定型：channel 是字面量联合，"staging" 这类拼错的值编译器直接拦。
export interface Site {
    name: string;
    port: number;
    channel: "stable" | "preview";
}

export const WEB_SITES: Site[] = [
    { name: "alpha", port: 28091, channel: "stable" },
    { name: "beta", port: 28092, channel: "preview" },
];
