# Phase 2: GitHub repository and branch protection

**Goal:** the code lives on GitHub, and `main` can only change through a **Pull Request**.

**Done when:** a direct `git push` to `main` is refused by GitHub.

**Repository:** https://github.com/bhaskarDhi/notes-devops (public)

---

## 2.1 Why protect `main`?

`main` is what gets deployed (Phase 7). If anyone can push to it directly, untested code goes straight to production. With protection:

```text
feature branch ──push──► Pull Request ──(Jenkins tests ✅, Phase 6)──► merge into main ──► deploy
```

| Decision | Why |
|---|---|
| P2-1 One repo, public | Jenkins can read it without a token; nothing secret is in it (`.gitignore` keeps `.env` out) |
| P2-2 Create the GitHub repo **empty** (no README/licence/.gitignore) | an extra commit on GitHub would clash with the first push from the Mac |
| P2-3 First branch named `main` from the start (`git init -b main`) | no renaming later (beginner project needed `git branch -m master main`) |
| P2-4 **Ruleset** (not the older "branch protection rules") | GitHub's current system; one ruleset can cover several branches; status shown as Active/Evaluate/Disabled |
| P2-5 Required approvals: **0** | working alone: you cannot approve your own PR. In a team: 1 or more |
| P2-6 Status check (Jenkins ✅) added **later** (Phase 6) | GitHub can only require a check it has already seen |

---

## 2.2 Create the repository and push

On GitHub: **+ → New repository → `notes-devops` → Public → (no README, no .gitignore, no licence) → Create repository**.

```bash
cd ~/Documents/"nodejs cicd"
git init -b main
git add .
git status --short          # check: no .env, no node_modules
git commit -m "Phase 1: Notes app with tests and Docker"
git remote add origin https://github.com/bhaskarDhi/notes-devops.git
git push -u origin main
```

Result: **28 files** on GitHub; no `.env`, no `node_modules`.

---

## 2.3 The ruleset `protect-main`

**Settings → Rules → Rulesets → New ruleset → New branch ruleset**

| Field | Value | Why |
|---|---|---|
| Ruleset name | `protect-main` | |
| Enforcement status | **Active** | "Evaluate" only reports; "Disabled" does nothing |
| Bypass list | empty | the rule applies to you too |
| Target branches | **Include default branch** | = `main` |
| Restrict deletions | ✅ | nobody can delete `main` |
| Block force pushes | ✅ | nobody can rewrite history |
| Require a pull request before merging | ✅, approvals **0** | all changes via PR |

---

## 2.4 Testing the protection

```bash
git pull                                       # always be up to date first
git commit --allow-empty -m "test direct push 2"
git push
```

Expected (and what we got):

```text
remote: error: GH013: Repository rule violations found for refs/heads/main.
remote: - Changes must be made through a pull request.
 ! [remote rejected] main -> main (push declined due to repository rule violations)
```

Undo the local test commit:

```bash
git reset --hard origin/main      # make the local branch exactly like GitHub
```

---

## 2.5 The everyday flow from now on

```bash
git checkout main && git pull                  # start from the latest main
git checkout -b feature/short-name             # new branch for the change
# ... edit files ...
git add .
git commit -m "Describe the change"
git push -u origin feature/short-name          # upload the branch
```

On GitHub: **Compare & pull request → Create pull request → (Phase 6+: wait for Jenkins ✅) → Merge pull request → Delete branch**.

```bash
git checkout main && git pull                  # get the merged change
git branch -d feature/short-name               # delete the local branch
```

| Command | Meaning |
|---|---|
| `git checkout -b NAME` | create a new branch and switch to it |
| `git push -u origin NAME` | upload the branch; `-u` remembers the link |
| `git branch -d NAME` | delete a local branch that is already merged |
| `git reset --hard origin/main` | throw away local commits; match GitHub exactly |

---

## 2.6 Problems and lessons

### The first protection test got through (`test direct push` is on `main`)
- **Cause:** the ruleset had not been created yet.
- **Effect:** an empty commit on `main`; harmless, and it cannot be removed because force pushes are blocked (which is the point).
- **Lesson:** a protection is only real after you have **tested** that it blocks.

### `! [rejected] main -> main (non-fast-forward)`
- **Cause:** the Mac was behind GitHub (it did not have `ddbf581` yet). Git refuses a push that would overwrite commits it doesn't have, with or without rules.
- **Fix:** `git pull` first.
- **How to tell the difference:** `non-fast-forward` = you are behind. `GH013 ... rule violations` = the ruleset blocked you.
