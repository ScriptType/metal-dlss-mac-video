#!/usr/bin/env python3
"""Oracle for docs/goal/GOAL.md. Prints one line per check and a final status line.

--quick skips scripts/check.sh; only a full run can report the met status.
"""
import hashlib, json, re, subprocess, sys
from datetime import datetime, timezone
from pathlib import Path

REPO = "ScriptType/metal-dlss-mac-video"
MILESTONE = "v1.0 (M3)"
HUMAN = "human"
AGENT = "agent"
CONTRACTS = {
    3: (HUMAN, "a4d578d39bdcf4673b312a0efa58755952a573d9343516b95a78ce51c8bddb90"), 16: (HUMAN, "2864d0b2301d3b7d2af82785b1afbeaad05ba3cfbb535a893fb73d41cff1cf97"), 17: (HUMAN, "980e930eb005e997008a77e23d7d2383658f9491567274217f65d35a15a204d7"), 39: (HUMAN, "637adb7c7eba7faa900112468bf51b67191bfdfb7861cbcba7f8a263eaf9d5e1"),
    34: (AGENT, "a3d17bf6492aed4fe58ada7d1d5e2d969be43f531fe5fb3a185ffe138a45dc4d"), 35: (AGENT, "51902baffadc103d9de076d5eb55b7ec4be4907f3c703b0db881fd5b8c1b7e9c"), 36: (AGENT, "a80f3eab022d8ce0a6925da3e23a8ce7257abd86cf947134033d649308a6afe9"), 37: (AGENT, "7ead36f9b5ca7df9cf73b41d3aa7908ad084f72ea931e57c33c5daec259ed604"),
    38: (AGENT, "ebd7f2f61a8260d004f6be05e2b112911759223db58c6fb7f2b0527a89f538a3"), 40: (AGENT, "aa5e075f98c035c9a4e16bc0256df853bf5a2274a7655da64785cbbb06859dd2"), 41: (AGENT, "f11be436949a3964302591279fd00f8ed784b492257c4e96020f1c64136ecfcd"), 42: (AGENT, "5d0356dae0db3b7d63e23f893537d860892aa4517663833564a30a2f270d7c8b"),
}
SUBMODULES = ["vendor/mpv", "vendor/MLX-DLSS", "vendor/Erika"]
ROOT = Path(__file__).resolve().parent.parent
failures = 0


def report(status, text):
    global failures
    print(f"{status:<5} {text}")
    if status != "PASS":
        failures += 1


def run(*args, cwd=ROOT):
    return subprocess.run(args, cwd=cwd, capture_output=True, text=True)


def contract_hash(body):
    lines = [re.sub(r"\[[xX]\]", "[ ]", line).rstrip() for line in body.replace("\r", "").split("\n")]
    return hashlib.sha256("\n".join(lines).strip().encode()).hexdigest()


def unticked(body):
    return [line.strip() for line in body.splitlines() if re.match(r"\s*- \[ \]", line)]


def fetch_issues():
    query = """query($owner:String!,$name:String!){repository(owner:$owner,name:$name){
      milestones(first:50,states:[OPEN,CLOSED]){nodes{title issues(first:100,states:[OPEN,CLOSED]){nodes{
        number state stateReason body labels(first:30){nodes{name}}
        closedByPullRequestsReferences(first:10,includeClosedPrs:true){nodes{number merged}}}}}}}}"""
    owner, name = REPO.split("/")
    out = run("gh", "api", "graphql", "-f", f"query={query}", "-f", f"owner={owner}", "-f", f"name={name}")
    if out.returncode:
        return None
    for milestone in json.loads(out.stdout)["data"]["repository"]["milestones"]["nodes"]:
        if milestone["title"] == MILESTONE:
            return {i["number"]: i for i in milestone["issues"]["nodes"]}
    return {}


def check_issues():
    issues = fetch_issues()
    if issues is None:
        report("FAIL", "GitHub query failed")
        return
    for number, (kind, pinned) in CONTRACTS.items():
        issue = issues.get(number)
        if issue is None:
            report("FAIL", f"#{number} is missing from '{MILESTONE}'")
            continue
        if contract_hash(issue["body"]) != pinned:
            report("FAIL", f"#{number} contract text changed since it was pinned")
            continue
        labels = {l["name"] for l in issue["labels"]["nodes"]}
        open_items = unticked(issue["body"])
        if issue["state"] == "CLOSED":
            merged = any(pr["merged"] for pr in issue["closedByPullRequestsReferences"]["nodes"])
            if issue["stateReason"] != "COMPLETED":
                report("FAIL", f"#{number} closed as {issue['stateReason']}")
            elif open_items:
                report("FAIL", f"#{number} closed with {len(open_items)} unticked item(s)")
            elif kind == AGENT and not merged:
                report("FAIL", f"#{number} closed without a merged PR")
            else:
                report("PASS", f"#{number} done")
        elif kind == HUMAN and {"needs-human", "ready-for-human"} <= labels and all("Human" in i for i in open_items):
            report("PASS", f"#{number} waits only on human items ({len(open_items)})")
        else:
            report("FAIL", f"#{number} open ({len(open_items)} unticked)")
    for number, issue in issues.items():
        if number not in CONTRACTS and issue["state"] == "OPEN":
            report("FAIL", f"#{number} (added to '{MILESTONE}') is open")
    open_prs = run("gh", "pr", "list", "--repo", REPO, "--state", "open", "--json", "number", "-q", ".[].number").stdout.split()
    report("PASS" if not open_prs else "FAIL", "no open PRs" if not open_prs else f"open PRs: {' '.join(open_prs)}")


def check_tree(label):
    if run("git", "status", "--porcelain", "--ignore-submodules=none").stdout.strip():
        report("FAIL", f"working tree is dirty {label}")
    elif run("git", "rev-parse", "HEAD").stdout != run("git", "rev-parse", "origin/main").stdout:
        report("FAIL", "HEAD is not origin/main")
    else:
        report("PASS", f"clean tree at origin/main {label}")


def main():
    quick = "--quick" in sys.argv[1:]
    check_issues()
    if run("git", "fetch", "-q", "origin", "main").returncode:
        report("FAIL", "git fetch origin main failed")
    check_tree("before check")
    oracle_commits = run("git", "log", "--format=%H", "origin/main", "--", "scripts/goal-status.py").stdout.split()
    report("PASS" if len(oracle_commits) == 1 else "FAIL", f"oracle has {len(oracle_commits)} commit(s) on origin/main")
    for sub in SUBMODULES:
        pin = run("git", "ls-tree", "HEAD", sub).stdout.split()[2]
        run("git", "fetch", "-q", "origin", "hdr-player", cwd=ROOT / sub)
        on_branch = run("git", "merge-base", "--is-ancestor", pin, "origin/hdr-player", cwd=ROOT / sub).returncode == 0
        report("PASS" if on_branch else "FAIL", f"{sub} pin {pin[:9]} {'is' if on_branch else 'is not'} on origin/hdr-player")
    if quick:
        report("SKIP", "scripts/check.sh (--quick)")
    else:
        log = ROOT / "artifacts" / "goal-check.log"
        with open(log, "w") as out:
            ok = subprocess.run(["bash", "scripts/check.sh"], cwd=ROOT, stdout=out, stderr=subprocess.STDOUT).returncode == 0
        report("PASS" if ok else "FAIL", "scripts/check.sh exit 0" if ok else f"scripts/check.sh failed, see {log}")
        if not ok:
            print("\n".join(log.read_text().splitlines()[-15:]))
        check_tree("after check")
    if oracle_commits:
        print("INFO  check.sh changes since the oracle landed:")
        print(run("git", "diff", "--stat", oracle_commits[-1], "HEAD", "--", "scripts/check.sh").stdout.rstrip() or "      none")
    head = run("git", "rev-parse", "HEAD").stdout.strip()
    verdict = "MET" if failures == 0 else f"NOT MET ({failures})"
    print(f"GOAL STATUS: {verdict} at {head} {datetime.now(timezone.utc):%Y-%m-%dT%H:%MZ}")
    return 0 if failures == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
