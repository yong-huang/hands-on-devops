// =============================================================================
// 06 · CrossGuard 策略包 —— preview 门禁的组织规范
//
// 策略在 preview 时对每条资源体检：违规且 enforcementLevel=mandatory →
// preview 直接失败（拦截）。单测管"程序声明的对不对"，策略管"声明合不合规范"；
// 两道门禁都过，才轮到真实部署。
// =============================================================================
import { PolicyPack } from "@pulumi/policy";

new PolicyPack("pulumi06", {
    policies: [
        {
            name: "no-latest-image",
            description: "容器镜像必须带明确的非 latest 标签",
            enforcementLevel: "mandatory",
            validateResource: (args, reportViolation) => {
                if (args.type !== "docker:index/container:Container") return;
                const image = String(args.props.image ?? "");
                if (!image.includes(":") || image.endsWith(":latest")) {
                    reportViolation(`镜像 "${image}" 缺少明确标签或使用 latest（不可复现）`);
                }
            },
        },
        {
            name: "required-labels",
            description: "容器必须带 managed-by 管理标签",
            enforcementLevel: "mandatory",
            validateResource: (args, reportViolation) => {
                if (args.type !== "docker:index/container:Container") return;
                // docker SDK 5.2.0 的 labels 是 {label, value} 数组（TF bridge 形态）
                const labels = (args.props.labels ?? []) as { label?: string; value?: string }[];
                const ok = labels.some((l) => l.label === "managed-by" && !!l.value);
                if (!ok) {
                    reportViolation("容器缺少 managed-by 标签（无法追溯归属）");
                }
            },
        },
    ],
});
