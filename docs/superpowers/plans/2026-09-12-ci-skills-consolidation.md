# CI Skills Consolidation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Make the repository's CI skills consistent with the root operational rules, reduce duplicated GitLab/Kaniko guidance, and remove unsafe production defaults.

**Architecture:** Add one shared `ci-gitlab-kaniko` skill for registry, workflow, environment mapping, build, and Kubernetes deployment conventions. Keep six language-specific skills focused on project detection and language/runtime differences, referencing the shared skill instead of duplicating its common template. Apply targeted safety corrections to PHP, Python, Java, and package-manager guidance.

**Tech Stack:** Markdown Agent Skills, GitLab CI, Kaniko, Kubernetes, Dockerfiles.

**Spec:** Approved in conversation on 2026-09-12; no separate design document was requested.

## Global Constraints

- Preserve upstream `image:` and Dockerfile `FROM` references; node-level containerd mirrors provide image acceleration.
- Push self-built images to `registry.cn-hangzhou.aliyuncs.com/sxxpqp`, not the Harbor pull-through proxy.
- Do not package `.env` secrets into production images by default.
- Do not skip Java tests by default.
- Do not silently fall back from frozen lockfile installation.
- Do not touch the user's existing `mysql/xtrabackup/backup.sh` modification.
- Do not modify production YAML, business scripts, or the root `CLAUDE.md`.
- Do not commit or push changes.

---

### Task 1: Add shared GitLab/Kaniko skill

**Files:**
- Create: `.claude/skills/ci-gitlab-kaniko/SKILL.md`

- [ ] **Step 1: Write the shared skill**

Create a concise skill with `name: ci-gitlab-kaniko` and a `description` beginning with `Use when...`. Cover the shared source rules, variables (`IMAGE_REGISTRY`, `IMAGE_NAMESPACE`, `IMAGE_NAME`, `IMAGE_TAG`, `K8S_NAMESPACE`, `K8S_DEPLOYMENT`), manual/web/api/trigger workflow rules, Kaniko push to ACR, protected registry credentials, branch mapping, and `kubectl set image` plus rollout status. Explicitly state that upstream `FROM`/`image:` values stay unchanged and that the skill does not apply to image mirror configuration.

- [ ] **Step 2: Validate the new skill text**

Check that it contains no Harbor push target, no secret values, and no instructions to rewrite upstream image references. Confirm its frontmatter description is trigger-oriented and under the skill frontmatter limit.

---

### Task 2: Normalize CI skill frontmatter and shared references

**Files:**
- Modify: `.claude/skills/ci-go/SKILL.md:1-3,84-237,241-247`
- Modify: `.claude/skills/ci-java-maven/SKILL.md:1-3,69-275,279-286`
- Modify: `.claude/skills/ci-python/SKILL.md:1-3,78-290,293-300`
- Modify: `.claude/skills/ci-php/SKILL.md:1-3,159-448,452-459`
- Modify: `.claude/skills/ci-react-vite/SKILL.md:1-3,103-307,311-318`
- Modify: `.claude/skills/ci-vue-vite/SKILL.md:1-3,174-401,405-412`

- [ ] **Step 1: Replace descriptions**

Use trigger-first descriptions beginning with `Use when...`; make React and Vue project predicates distinct, and state non-applicability for unrelated languages or generic shell work.

- [ ] **Step 2: Remove duplicated shared CI template sections**

Keep each language skill's language-specific build/runtime material and replace its duplicated GitLab workflow/deploy template with a short “Shared GitLab/Kaniko pipeline” section that references `ci-gitlab-kaniko` by skill name and lists only language-specific variables or build arguments.

- [ ] **Step 3: Normalize language-specific CI guidance**

Ensure all remaining examples use `IMAGE_REGISTRY=registry.cn-hangzhou.aliyuncs.com`, `IMAGE_NAMESPACE=sxxpqp`, while Dockerfile `FROM` and Kubernetes third-party `image:` examples remain upstream. Remove old `hub.wishfoxs.com` examples from these six skills.

- [ ] **Step 4: Validate duplication and trigger boundaries**

Search the six skills for `hub.wishfoxs.com`, `HARBOR_REGISTRY`, and full duplicated `workflow:` blocks. Confirm only the shared skill owns those common rules.

---

### Task 3: Fix Java, package-manager, Python, and PHP unsafe defaults

**Files:**
- Modify: `.claude/skills/ci-java-maven/SKILL.md`
- Modify: `.claude/skills/ci-vue-vite/SKILL.md`
- Modify: `.claude/skills/ci-react-vite/SKILL.md`
- Modify: `.claude/skills/ci-python/SKILL.md`
- Modify: `.claude/skills/ci-php/SKILL.md`

- [ ] **Step 1: Make Java tests run by default**

Change the Maven example to omit `-DskipTests` by default. Document an explicit opt-in variable or command for exceptional test skipping rather than making it the production template default.

- [ ] **Step 2: Remove silent frozen-lockfile fallback**

Change pnpm examples from `frozen-lockfile || pnpm install` to a deterministic frozen-lockfile install. Explain that missing or stale lockfiles must fail and be corrected before CI proceeds.

- [ ] **Step 3: Make Python runtime non-root**

Update the main Python Dockerfile example to create/use UID 10001 and ensure application directories are readable/writable as required before `USER`.

- [ ] **Step 4: Remove `.env` image baking as the default PHP path**

Change the PHP template to use runtime K8s Secret/ConfigMap injection. Retain only a clearly labeled legacy exception if needed by existing projects, without showing real credentials.

- [ ] **Step 5: Replace unsafe Composer installer piping**

Use a download-then-execute pattern for Composer and require integrity verification or a trusted pinned Composer image/tool source. Do not retain `curl ... | php` as the default.

- [ ] **Step 6: Validate security defaults**

Search for `-DskipTests`, `|| pnpm install`, `COPY ${ENV_FILE} .env`, `curl ... | php`, and missing Python `USER`; inspect every remaining occurrence and ensure it is either removed or explicitly labeled as a legacy exception.

---

### Task 4: Add deletion checkpoint to Kubernetes cleanup skill

**Files:**
- Modify: `.claude/skills/k8s-cleanup-stuck/SKILL.md:49-121`

- [ ] **Step 1: Separate diagnosis from destructive cleanup**

Add a read-only diagnosis phase that lists the CRs, namespaces, webhooks, and RBAC objects affected.

- [ ] **Step 2: Add explicit confirmation checkpoint**

Before the existing finalizer removal, scale, webhook deletion, namespace deletion, or RBAC deletion commands, insert a visible `🔴 CHECKPOINT · STOP` requiring user confirmation and list the destructive operations covered.

- [ ] **Step 3: Preserve immediate unstick commands as post-confirmation actions**

Keep the ordered cleanup logic, but make it clear that commands after the checkpoint are not run until confirmation is received. Add post-action verification for remaining Terminating resources and webhook configurations.

- [ ] **Step 4: Validate destructive-command gating**

Search the skill for `kubectl delete`, `kubectl replace --raw`, `finalizers`, and `scale`; confirm each destructive path is below the checkpoint or clearly marked as diagnostic/read-only.

---

### Task 5: Correct Darwin resource claims

**Files:**
- Modify: `.claude/skills/darwin-skill/SKILL.md:62-86,108-160,276-286,432-475`

- [ ] **Step 1: Remove or qualify unavailable resources**

Because the current directory contains only `darwin-skill/SKILL.md`, remove claims that `references/skilllens-evidence.md`, `references/runtime-neutrality.md`, `templates/`, `scripts/screenshot.mjs`, `results.tsv`, or per-skill `test-prompts.json` already exist. Describe them as optional resources that must be created before use, or restrict the skill to static review mode.

- [ ] **Step 2: State validation limits**

Make clear that no “full_test” or score claim is valid without independent test agents and actual prompt fixtures; otherwise report a dry run explicitly.

- [ ] **Step 3: Validate references**

Check every remaining relative path in the Darwin skill against the actual directory. No required path may point to a missing file.

---

### Task 6: Final repository validation

**Files:**
- Test only: all modified `.claude/skills/**/SKILL.md`

- [ ] **Step 1: Run structural searches**

Verify all skill frontmatter blocks have `name` and trigger-first `description`; verify no CI skill contains `hub.wishfoxs.com`, `HARBOR_REGISTRY`, default `.env` baking, Java test skipping, or silent pnpm fallback.

- [ ] **Step 2: Check references and scope**

Confirm `ci-gitlab-kaniko` exists, all skill-name references resolve, no production files changed, and `mysql/xtrabackup/backup.sh` remains untouched by this work.

- [ ] **Step 3: Review the diff**

Inspect `git diff --stat` and the complete diff for accidental reformatting, secrets, unrelated files, or loss of language-specific guidance. Do not commit or push.
