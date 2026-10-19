// 真仓库版 semantic-release 配置（推到 yong-huang/cicd-lab）：
// commit-analyzer 定版本递升、release-notes-generator 写 changelog、
// github 插件发 GitHub Release（GITHUB_TOKEN 由 workflow 注入）
module.exports = {
  branches: ["main"],
  tagFormat: "v${version}",
  plugins: [
    "@semantic-release/commit-analyzer",
    "@semantic-release/release-notes-generator",
    "@semantic-release/github",
  ],
};
