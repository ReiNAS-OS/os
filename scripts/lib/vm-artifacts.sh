# ReiNAS OS — 从 CI 拉镜像产物
#
# 被 vm.sh source。依赖 lib/vm-common.sh 里的 log/ok/warn/die/vm_dir/image_version。

# ─────────────────────────────────────────────────────────────
#  CI 产物
# ─────────────────────────────────────────────────────────────

list_runs() {
    command -v gh >/dev/null || die "需要 gh CLI。装：brew install gh"
    gh run list -R "$REPO" --workflow "$WORKFLOW" --limit 10 \
        --json databaseId,createdAt,conclusion,status \
        --jq '.[] | "\(.databaseId)  \(.createdAt)  \(.status)/\(.conclusion // "-")"'
}

# 取最近一次成功构建的 run id。arch 已经是输入参数，两个架构各是一个 job，
# 所以这里只按「成功」筛，不区分架构。
latest_success_run() {
    gh run list -R "$REPO" --workflow "$WORKFLOW" --limit 20 \
        --json databaseId,conclusion \
        --jq '[.[] | select(.conclusion == "success")][0].databaseId'
}

# 下载单个 artifact 的 zip 并解到目标目录。
#
# 不用 `gh run download`：它对大 artifact 会报 "not a valid zip file" 并
# 整个失败（实测 raw.xz 卡在同一位置）。走 API + curl -C - 可以续传。
fetch_artifact() {
    local run_id="$1" name="$2" dest="$3"
    local id
    id=$(gh api "repos/$REPO/actions/runs/$run_id/artifacts" \
           --jq ".artifacts[] | select(.name == \"$name\") | .id" 2>/dev/null | head -1)
    if [ -z "$id" ]; then
        warn "这次构建没有 ${name} artifact"
        return 1
    fi

    local zip="$dest/$name.zip"
    mkdir -p "$dest"
    log "下载 ${name}（artifact ${id}）"
    curl -sSL -C - --retry 5 --retry-delay 3 --retry-all-errors \
        -H "Authorization: token $(gh auth token)" \
        -H "Accept: application/vnd.github+json" \
        "https://api.github.com/repos/$REPO/actions/artifacts/$id/zip" \
        -o "$zip" || die "下载失败: $name"

    unzip -o -q "$zip" -d "$dest" || die "解压失败: $zip"
    rm -f "$zip"
    ok "$name"
}

pull() {
    local run_id="${1:-}"
    command -v gh >/dev/null || die "需要 gh CLI。装：brew install gh"

    if [ -z "$run_id" ]; then
        run_id=$(latest_success_run)
        [ -n "$run_id" ] && [ "$run_id" != "null" ] \
            || die "找不到成功的构建。先用 workflow_dispatch 手动跑一次。"
    fi

    local dir; dir=$(vm_dir)
    local ver; ver=$(image_version)
    mkdir -p "$dir"

    log "拉 ${ARCH} 产物，run ${run_id}（版本 ${ver}）"
    log "落在 $dir"

    fetch_artifact "$run_id" "ReiNAS.$ARCH-$ver.raw.xz" "$dir"       || die "缺 raw"
    fetch_artifact "$run_id" "ReiNAS.$ARCH-$ver.install.iso" "$dir"  || true
    fetch_artifact "$run_id" "reinas-lock-$ARCH" "$dir"              || true
    fetch_artifact "$run_id" "build-log-$ARCH" "$dir/build-log"      || true

    local xz="$dir/ReiNAS.$ARCH-$ver.raw.xz"
    if [ -f "$xz" ]; then
        log "校验 xz"
        xz -t "$xz" || die "xz 损坏，重跑 pull"
        if [ ! -f "$dir/ReiNAS.$ARCH-$ver.raw" ]; then
            log "解开 raw（约 8G，十几秒）"
            xz -dk -T0 "$xz"
        fi
        ok "$(ls -lh "$dir/ReiNAS.$ARCH-$ver.raw" | awk '{print $5}') raw"
    fi

    ok "产物就绪。下一步：./scripts/vm.sh boot"
}
