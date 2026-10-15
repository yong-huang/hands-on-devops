# 06 · 给 IaC 写测试：mocks 单测 + CrossGuard 策略

> 期望态是一段程序，程序就能测试。本实验给同一份声明装两道门禁：mocks 单测
> 用假引擎跑程序、断言声明的属性；CrossGuard 策略在 preview（Pulumi 的预演命令：只算变更、不真正执行）时
> 逐条资源体检，
> 违规（latest 镜像、丢管理标签）直接拦截。全程止步 preview，不创建任何真实
> 资源——Docker 甚至不用跑。

## Background

没有测试的 IaC（Infrastructure as Code，基础设施即代码：用代码声明基础设施
的期望状态）靠什么保证质量？靠 `up`（Pulumi 真正创建资源的部署命令）执行之后
肉眼检查——镜像写错、标签漏带，都是部署后才发现，回滚就是一次事故。

应用代码早有单元测试，IaC 的声明代码却长期"裸奔"：毕竟资源要部署出来才能
验证，测什么呢？

两个答案把验证提前到部署之前。单元测试层面：把引擎换成假实现，程序照常执行，
测的是"声明的期望态对不对"。策略层面：对每条资源跑组织规范（禁 latest、
必带标签），违规即拒绝。

这类"策略即代码"常用 OPA（Open Policy Agent，独立的通用策略引擎）外挂实现，
Pulumi 把它内置成了 CrossGuard，preview 一条命令带上。

## What

**定义**：mocks 是测试期替身引擎——拦下引擎对真实 API 的调用，资源"登记"即
返回；策略包（Policy Pack）是挂在 preview 上的规则集——对每条资源执行检查
回调，违规按 enforcementLevel（执行级别：mandatory 阻断 / advisory 仅告警）处置。

| 部件 | 角色 |
|:---|:---|
| `pulumi.runtime.setMocks` | 测试里启用假引擎：`newResource` 回调决定"登记"时返回什么 |
| `mocha` + `npm test` | 跑断言：镜像、端口、标签、URN（Pulumi 给每个资源的全局唯一名字串，形如 `urn:pulumi:dev::项目::类型::逻辑名`）都是普通值检查 |
| `new PolicyPack(...)` | 策略包：一组具名规则，`policy/` 目录独立成包 |
| `validateResource` 回调 | 每条资源进来一次：`args.type` 认类型，违规就 `reportViolation` |
| `pulumi preview --policy-pack` | 把策略挂上 preview：绿灯放行，mandatory 违规退出码非 0 |

可以把两道门禁想象成代码评审的两个自动化替身：单测是"测试框架"那一栏——
验逻辑对不对；策略是"lint 规则"那一栏——验写法合不合规范。但与 lint 不同的
是，策略绿灯不保证部署成功：镜像拉不拉得动、端口撞不撞，仍要 preview 与
`up` 才见分晓。

![两道门禁拦在部署前](images/policy_test.svg)

> 🌐 **交互版**：[在线打开（GitHub Pages）](https://yong-huang.github.io/hands-on-devops/pulumi/06_policy_test/images/policy_test.html)（或本地打开 [`images/policy_test.html`](images/policy_test.html)）。

看图方法：左边 infra.ts 是被测的期望态声明，中间的橙虚线区域是两道门禁，
右边 `pulumi up` 只有在两道门禁都绿时才轮得到；evil 配置走门禁 2 被当场拦截。

## When to Use

- 封装团队/平台组件时：规范（镜像来源、必带标签）焊进策略包，调用方想错都难；
- 接 CI 门禁：`npm test` 与 `preview --policy-pack` 都是退出码驱动的命令，
  天然能当流水线卡点（项目 12 会把它们接进 act）；
- 重构保护：改 `infra.ts` 时不改测试，绿灯即行为未变——IaC 也有"重构安全网"。
- 反例：一次性玩具声明，测它的时间比写它的时间长；规范还没成形时先别写策略包。

| 门禁方案 | 差异 | 什么时候选它 |
|:---|:---|:---|
| mocks 单测 | `npm test` 里断言声明，秒级、离线 | 项目内部质量，改声明时最快反馈 |
| CrossGuard 策略 | 挂在 preview 上按规范逐条拦截 | 团队/组织规范，调用方不自觉也拦得住 |
| OPA/Conftest 外挂 | 独立策略引擎，与 Pulumi 解耦 | 已有多套 IaC 工具、规范要跨工具共享 |

## Quick Start

前置：Pulumi CLI、Node.js 22。Docker **不需要**运行——本实验不创建真实资源。

```bash
cd pulumi/06_policy_test
./policy_test.sh          # 完整生命周期：test → policy → evil → clean
./policy_test.sh test     # npm test：mocks 单测全绿
./policy_test.sh policy   # 合规配置过策略门禁（绿）
./policy_test.sh evil     # 故意违规 → 门禁拦截（红）
./policy_test.sh clean    # 清空栈与日志
```

`test` 段的真实输出（节选）：

```
  web 容器的期望态（mocks 单测）
    ✔ 镜像带明确的非 latest 标签
    ✔ 发布在 28501 端口
    ✔ 带 managed-by 管理标签
    ✔ URN 指向 docker 容器类型（不是别的资源顶名）
  4 passing (2ms)
```

`evil` 段把配置开关拨到 `evil=true`（镜像变 `nginx:latest`、丢掉管理标签），
preview 的真实输出（节选）：

```
Policies:
    ❌ pulumi06@v0.1.0 (local: /Users/.../06_policy_test/policy)
        - [mandatory]  no-latest-image  (docker:index:Container: web)
          容器镜像必须带明确的非 latest 标签
          镜像 "nginx:latest" 缺少明确标签或使用 latest（不可复现）
        - [mandatory]  required-labels  (docker:index:Container: web)
          容器必须带 managed-by 管理标签
          容器缺少 managed-by 标签（无法追溯归属）
```

两条策略双双拦截，preview 退出码 1；`evil=false` 时同一策略包输出
`✅ pulumi06@v0.1.0`，preview 正常给出 `+ 3 to create` 的计划。

诚实预期：首次运行会先后安装 `program/` 与 `policy/` 两处依赖（约 1 分钟）；
Node 22 跑 mocha 时可能打 `MODULE_TYPELESS_PACKAGE_JSON` 警告（无害，转译提示）。

## How It Works

### mocks：换掉引擎，程序照跑

```ts
pulumi.runtime.setMocks({
    newResource: async (args) => ({
        id: `${args.name}-mock-id`,
        state: args.inputs,      // 程序传什么，"已实现状态"就是什么
    }),
    call: async (args) => ({ outputs: args.inputs, state: args.inputs }),
});
```

引擎被替身后，`new docker.Container(...)` 不再碰 Docker API：mock 返回固定 id，
并把程序传入的属性原样当状态回填。

Output 是"创建后才有值的未来值"——测试里用 `apply` 注册回调、包成 Promise 解出
普通值再断言（镜像、端口、标签、URN 四个用例，`npm test` 2ms 跑完）。

### 策略：每条资源过一遍体检

```ts
validateResource: (args, reportViolation) => {
    if (args.type !== "docker:index/container:Container") return;
    const image = String(args.props.image ?? "");
    if (!image.includes(":") || image.endsWith(":latest")) {
        reportViolation(`镜像 "${image}" 缺少明确标签或使用 latest（不可复现）`);
    }
},
```

`args.type` 是资源的类型串（与 URN 里的类型段一致），先认类型再做检查；
`args.props` 是程序声明的原始属性。`enforcementLevel: "mandatory"` 让违规从
"提示"升级为"preview 失败"——`evil` 段的退出码 1 就是这么来的。

### evil 开关：违规配置做成声明的分支

`infra.ts` 读配置 `evil`：false 时 `nginx:1.27-alpine` + 管理标签；true 时
`nginx:latest` 且不带标签。用配置开关而非临时改源码，拦截演示就可重复：
一个布尔值切换绿/红，演示完拨回来，期望态始终在版本控制里。

## Pitfalls & Q&A

- **① `labels` 的形态看 SDK**：`@pulumi/docker` 5.2.0 里它是
  `{ label, value }` 数组（@pulumi/docker 由 Terraform SDK 经桥接层自动生成，沿用了它的
  数组形态），不是 Terraform 习惯的字符串 map——传错形态 tsc 直接拦下。
- **② 策略包的 package.json 必须带 `version`**：缺了在 preview 加载时报
  `Version must be defined in the package.json file`。
- **③ `@pulumi/policy` 1.21.0 的类型包有打包缺陷**：直接 `tsc` 检查会报
  `proxy.d.ts` 导出缺失——策略目录 tsconfig 加 `skipLibCheck: true` 绕过；
  另外 `validateResource` 不是导出成员，未类型化检查用内联回调形式。

Q&A：

- **单测绿了，策略还会拦吗？** 会：两层各管一摊。单测管"程序声明的对不对"
  （镜像是不是配置里那个值），策略管"声明合不合规范"（latest 谁来了都拦）。
- **不用 Docker 真的能跑吗？** 能：mocks 替掉引擎、preview 只算计划不执行；
  唯一的前置是 provider 插件（Pulumi 针对每种目标平台的驱动程序，preview 也要
  实例化它；首次 preview 会自动安装，与实验 01 同款）。
- **advisory 和 mandatory 怎么选？** 强规范（安全、合规）用 mandatory 拦死；
  建议性规范（建议加备注）用 advisory 只告警——门禁太吵会被绕过，先少而准。
