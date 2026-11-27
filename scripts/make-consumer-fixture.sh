#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 1 ] || [ -z "${1:-}" ]; then
  echo "用法：$0 <目标目录>" >&2
  exit 1
fi

TARGET_DIR="$1"
if [ -e "$TARGET_DIR" ]; then
  echo "错误：目标目录已存在，拒绝覆盖：$TARGET_DIR" >&2
  exit 1
fi

SANDBOX_REPO="${SSOT_SANDBOX_REPO:-https://github.com/zeen-chat/ssot-sandbox.git}"
SANDBOX_BRANCH="${SSOT_SANDBOX_BRANCH:-main}"
SSOT_CLI_SPEC="${SSOT_CLI_SPEC:-git+ssh://git@github.com/zeen-chat/ssot-cli.git#v0.2.0-draft.3}"

echo "正在查询演习仓 ${SANDBOX_REPO} 分支 ${SANDBOX_BRANCH} 的最新提交..."
LOCKED_COMMIT="$(git ls-remote "$SANDBOX_REPO" "refs/heads/${SANDBOX_BRANCH}" | awk 'NR==1 {print $1}')"
if [[ ! "$LOCKED_COMMIT" =~ ^[0-9a-f]{40}([0-9a-f]{24})?$ ]]; then
  echo "错误：无法从 ${SANDBOX_REPO} 获取分支 ${SANDBOX_BRANCH} 的有效提交号。" >&2
  exit 1
fi

mkdir -p "$TARGET_DIR"
TARGET_ABS="$(cd "$TARGET_DIR" && pwd)"

TMP_PATCH_REPO=""
cleanup() {
  if [ -n "$TMP_PATCH_REPO" ] && [ -d "$TMP_PATCH_REPO" ]; then
    rm -rf "$TMP_PATCH_REPO"
  fi
}
trap cleanup EXIT

cd "$TARGET_ABS"

git init -b main >/dev/null
git config user.name "sandbox-drill"
git config user.email "sandbox-drill@example.invalid"

cat > .gitignore <<'EOF'
.ssot/
node_modules/
EOF

cat > package.json <<EOF
{
  "name": "ssot-sandbox-consumer-fixture",
  "version": "0.1.0",
  "private": true,
  "type": "module",
  "scripts": {
    "ssot": "ssot",
    "test": "node --test tests/**/*.test.mjs"
  },
  "devDependencies": {
    "@zeen-chat/ssot": "${SSOT_CLI_SPEC}"
  }
}
EOF

echo "正在安装 @zeen-chat/ssot（${SSOT_CLI_SPEC}）..."
npm install --no-fund --no-audit

cat > ssot.lock.yaml <<EOF
version: 1
sources:
  - name: sandbox
    repo: ${SANDBOX_REPO}
    branch: ${SANDBOX_BRANCH}
    commit: ${LOCKED_COMMIT}
    paths:
      - product
    scope:
      - types:
          - demo-card
          - demo-spec
    ignored: []
    pending: []
verify:
  tests:
    - "tests/**/*.test.*"
  strict: false
propose:
  token_env: SSOT_BOT_TOKEN
EOF

mkdir -p tests
cat > tests/demo.test.mjs <<'EOF'
import test from "node:test";
import assert from "node:assert/strict";

function validateTodoTitle(raw) {
  const trimmed = String(raw ?? "").trim();
  if (trimmed.length === 0) return { ok: false, reason: "标题不能为空" };
  if (trimmed.length > 50) return { ok: false, reason: "标题超过 50 个字符" };
  if (/[\r\n\x00-\x1f\x7f]/.test(trimmed)) return { ok: false, reason: "标题包含非法控制字符" };
  return { ok: true, value: trimmed };
}

test("[DEMO-01] 待办项标题去除首尾空白并校验长度与控制字符", () => {
  assert.deepEqual(validateTodoTitle("  准备演练材料  "), { ok: true, value: "准备演练材料" });
  assert.equal(validateTodoTitle("   ").ok, false);
  assert.equal(validateTodoTitle("a".repeat(51)).ok, false);
  assert.equal(validateTodoTitle("第一行\n第二行").ok, false);
});

test("[DEMO-02] 清单导出按单行输出且不静默截断标题", () => {
  const res = validateTodoTitle("整理示例清单");
  assert.equal(res.ok, true);
  assert.equal(res.value.includes("\n"), false);
});
EOF

echo "正在运行 ssot sync 检出锁定提交 ${LOCKED_COMMIT:0:12}..."
npx --no-install ssot sync

DEMO01_REL="product/modules/DEMO/DEMO-01-示例条目.md"
DEMO01_SYNCED="${TARGET_ABS}/.ssot/sandbox/${DEMO01_REL}"
if [ ! -f "$DEMO01_SYNCED" ]; then
  echo "错误：同步后未找到 ${DEMO01_SYNCED}，请确认演习仓分支 ${SANDBOX_BRANCH} 已包含完整示例条目。" >&2
  exit 1
fi

# 基于锁定提交的真实文件内容生成带完整 Git index 头的补丁，供 ssot propose --3way 使用
TMP_PATCH_REPO="$(mktemp -d)"
git -C "$TMP_PATCH_REPO" init -b main >/dev/null
git -C "$TMP_PATCH_REPO" config user.name "sandbox-drill"
git -C "$TMP_PATCH_REPO" config user.email "sandbox-drill@example.invalid"
mkdir -p "${TMP_PATCH_REPO}/$(dirname "$DEMO01_REL")"
cp "$DEMO01_SYNCED" "${TMP_PATCH_REPO}/${DEMO01_REL}"
chmod u+w "${TMP_PATCH_REPO}/${DEMO01_REL}"
git -C "$TMP_PATCH_REPO" add "$DEMO01_REL"
git -C "$TMP_PATCH_REPO" commit -m "基线" >/dev/null

printf '4. 待办项标题内的连续空白字符在保存前折叠为单个空格。\n' >> "${TMP_PATCH_REPO}/${DEMO01_REL}"
git -C "$TMP_PATCH_REPO" diff > "${TARGET_ABS}/proposal.patch"

if [ ! -s "${TARGET_ABS}/proposal.patch" ]; then
  echo "错误：生成的 proposal.patch 为空。" >&2
  exit 1
fi

cat > "${TARGET_ABS}/triage.md" <<'EOF'
# 演练提案分诊摘要

- 提案条目：`DEMO-01`（示例待办项标题规范）
- 改动摘要：新增第 4 条规则，约定保存前将标题内连续空白字符折叠为单个空格。
- 影响范围：直接改动 `DEMO-01`，下游 `DEMO-02`（示例清单导出规范）受影响，导出前需复核空白折叠口径。
- 业务仓计划：待事实源 PR 批准合入并推进锁文件后，在业务仓补齐空格折叠实现与 `[DEMO-01]`、`[DEMO-02]` 测试断言。
EOF

git add .gitignore package.json package-lock.json ssot.lock.yaml tests/demo.test.mjs proposal.patch triage.md
git commit -m "初始化演练业务仓夹具" >/dev/null

echo ""
echo "业务仓夹具已就绪：${TARGET_ABS}"
echo "锁定来源：${SANDBOX_REPO}（分支 ${SANDBOX_BRANCH}，提交 ${LOCKED_COMMIT:0:12}）"
echo "下一步可在夹具目录运行："
echo "  cd \"${TARGET_ABS}\""
echo "  npx ssot status"
echo "  npx ssot verify"
echo "  npx ssot propose --patch proposal.patch --reason \"演练\" --triage-file triage.md --dry-run"
