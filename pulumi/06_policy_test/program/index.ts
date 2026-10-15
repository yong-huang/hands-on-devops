// 正常部署入口：本实验止步 preview（不 up），但这不妨碍它随时被真实部署——
// 期望态声明与门禁分离，正是 IaC 可测试的前提。
import { defineInfra } from "./infra";

defineInfra();
