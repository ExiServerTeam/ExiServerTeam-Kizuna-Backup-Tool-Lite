#!/usr/bin/env bash
# =============================================================================
# Kizuna-Backup LITE v1.7 無料版
# Pro版はこちらからhttps://kizuna-backup.booth.pm/items/8714949
# =============================================================================


set -Eeuo pipefail

VERSION="1.7"
SCRIPT_NAME="$(basename "$0")"

# =============================================================================
# 設定デフォルト値
# =============================================================================
MODE="sync"
SSH_PORT="22"
SSH_KEY=""
DRY_RUN=false

TARGET_DIR=""
REMOTE_DEST=""
REMOTE_USER=""
REMOTE_HOST=""
REMOTE_DIR=""

LOG_FILE="${TMPDIR:-/tmp}/kizuna-lite-$(id -u).log"

LOCK_FILE=""
LOCAL_BACKUP=""
SSH_CMD=()
RSYNC_SSH_STR=""

KEEP_LOCAL_BACKUP=false

# =============================================================================
# ログ関数
# =============================================================================
log() {
    local ts level msg
    ts="$(date '+%Y-%m-%d %H:%M:%S')"
    level="$1"
    msg="$2"
    printf '[%s] [%s] %s\n' "$ts" "$level" "$msg" | tee -a "$LOG_FILE"
}
log_info(){ log INFO "$1"; }
log_warn(){ log WARN "$1"; }
log_error(){ log ERROR "$1"; }

# =============================================================================
# shell_quote
# =============================================================================
shell_quote() {
    printf "'%s'" "${1//\'/\'\\\'\'}"
}

# =============================================================================
# ポート番号バリデーション
# =============================================================================
is_valid_port() {
    [[ "$1" =~ ^[0-9]+$ ]] && (( 10#$1 >= 1 && 10#$1 <= 65535 ))
}

# =============================================================================
# ヘルプ表示
# =============================================================================
show_help() {
    cat << EOF
$SCRIPT_NAME v$VERSION - Kizuna-Backup LITE（無料版）

使い方:
  $SCRIPT_NAME [オプション] <対象ディレクトリ> <user@host> <リモートパス>

オプション:
  -m, --mode sync|archive   バックアップ方式（デフォルト: sync）
  -k, --key <鍵ファイル>    SSH秘密鍵
  -p, --port <ポート>       SSHポート（デフォルト: 22）
  --dry-run                 シミュレーションモード（実際には転送しない）
  -h, --help                ヘルプ表示

例:
  $SCRIPT_NAME /home/user/data backup@192.168.1.100 /backup/data
  $SCRIPT_NAME /var/www user@server.com /backup/www --mode archive
  $SCRIPT_NAME /etc root@10.0.0.1 /backup/etc --dry-run

PRO版（500円）では世代管理・GPG暗号化・通知・cron自動化が利用できます。
https://kizuna-backup.booth.pm/items/8714949
EOF
}

# =============================================================================
# 引数解析
# =============================================================================
parse_args() {
    local args=()

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -m|--mode)
                MODE="$2"
                shift 2
                ;;
            -k|--key)
                SSH_KEY="$2"
                shift 2
                ;;
            -p|--port)
                SSH_PORT="$2"
                shift 2
                ;;
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            -h|--help)
                show_help
                exit 0
                ;;
            --)
                shift
                while [[ $# -gt 0 ]]; do
                    args+=("$1")
                    shift
                done
                ;;
            -*)
                log_error "不明なオプション: $1"
                exit 1
                ;;
            *)
                args+=("$1")
                shift
                ;;
        esac
    done

    if (( ${#args[@]} != 3 )); then
        log_error "引数は3つ必要です（対象ディレクトリ user@host リモートパス）"
        exit 1
    fi

    TARGET_DIR="${args[0]}"
    REMOTE_DEST="${args[1]}"
    REMOTE_DIR="${args[2]}"

    # 対象ディレクトリ存在チェック
    if [[ ! -d "$TARGET_DIR" ]]; then
        log_error "対象ディレクトリが存在しません: $TARGET_DIR"
        exit 1
    fi

    # モードチェック
    if [[ "$MODE" != "sync" && "$MODE" != "archive" ]]; then
        log_error "MODE は sync または archive を指定してください"
        exit 1
    fi

    # ポート番号チェック
    if ! is_valid_port "$SSH_PORT"; then
        log_error "SSHポートが不正です: $SSH_PORT"
        exit 1
    fi

    # SSH鍵チェック
    if [[ -n "$SSH_KEY" ]]; then
        if [[ ! -f "$SSH_KEY" ]]; then
            log_error "SSH鍵ファイルが存在しません: $SSH_KEY"
            exit 1
        fi
        if [[ ! -r "$SSH_KEY" ]]; then
            log_error "SSH鍵ファイルを読み取れません: $SSH_KEY"
            exit 1
        fi
    fi

    # user@host 形式チェック
    if [[ "$REMOTE_DEST" != *@* ]]; then
        log_error "接続先は user@host の形式で指定してください"
        exit 1
    fi

    REMOTE_USER="${REMOTE_DEST%%@*}"
    REMOTE_HOST="${REMOTE_DEST#*@}"

    if [[ -z "$REMOTE_USER" ]]; then
        log_error "リモートユーザーが空です"
        exit 1
    fi
    if [[ -z "$REMOTE_HOST" ]]; then
        log_error "リモートホストが空です"
        exit 1
    fi
    if [[ "$REMOTE_DIR" == "/" ]]; then
        log_error "リモートパスに /（ルート）は指定できません"
        exit 1
    fi
}

# =============================================================================
# 依存コマンドチェック
# =============================================================================
check_dependencies() {
    local cmds=(ssh rsync tar sha256sum flock awk du mkdir rm)
    local missing=()

    for c in "${cmds[@]}"; do
        if ! command -v "$c" >/dev/null 2>&1; then
            missing+=("$c")
        fi
    done

    if (( ${#missing[@]} > 0 )); then
        log_error "以下のコマンドが見つかりません: ${missing[*]}"
        exit 1
    fi
}

# =============================================================================
# SSH構築
# =============================================================================
build_ssh_command() {
    SSH_CMD=(
        ssh -p "$SSH_PORT"
        -o BatchMode=yes
        -o ConnectTimeout=10
        -o StrictHostKeyChecking=accept-new
    )

    RSYNC_SSH_STR="ssh -p $SSH_PORT -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new"

    if [[ -n "$SSH_KEY" ]]; then
        SSH_CMD+=(-i "$SSH_KEY" -o IdentitiesOnly=yes)
        RSYNC_SSH_STR+=" -i $(printf '%q' "$SSH_KEY") -o IdentitiesOnly=yes"
    fi
}

# =============================================================================
# SSH接続テスト
# =============================================================================
test_ssh_connection() {
    if [[ "$DRY_RUN" == true ]]; then
        log_info "DRY-RUN: SSH接続テストをスキップ"
        return 0
    fi

    log_info "SSH接続確認中: ${REMOTE_USER}@${REMOTE_HOST}:${SSH_PORT}"

    if ! "${SSH_CMD[@]}" "${REMOTE_USER}@${REMOTE_HOST}" "echo OK" >/dev/null 2>&1; then
        log_error "SSH接続に失敗しました（ユーザー名・ホスト・鍵・ポートを確認）"
        return 1
    fi

    log_info "SSH接続OK"
}

# =============================================================================
# 排他制御
# =============================================================================
acquire_lock() {
    local lock_key
    lock_key="$(printf '%s\n' "${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_DIR}" | sha256sum | cut -c1-16)"
    LOCK_FILE="${TMPDIR:-/tmp}/kizuna-lite-${lock_key}.lock"

    exec 200>"$LOCK_FILE"
    if ! flock -n 200; then
        log_error "他のバックアップ処理が実行中です（送信先: ${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_DIR}）"
        exit 1
    fi
    log_info "ロック取得: $LOCK_FILE"
}

release_lock() {
    flock -u 200 2>/dev/null || true
    rm -f "$LOCK_FILE" 2>/dev/null || true
    log_info "ロック解放"
}

# =============================================================================
# 一時ファイルクリーンアップ
# =============================================================================
cleanup_temp() {
    if [[ -z "$LOCAL_BACKUP" || ! -f "$LOCAL_BACKUP" ]]; then
        return 0
    fi

    if [[ "$KEEP_LOCAL_BACKUP" == true ]]; then
        log_warn "失敗時バックアップを保持します: $LOCAL_BACKUP"
        return 0
    fi

    rm -f "$LOCAL_BACKUP" || true
    log_info "一時ファイル削除: $LOCAL_BACKUP"
}

cleanup() {
    local code=$?
    cleanup_temp
    release_lock
    exit "$code"
}
trap cleanup EXIT

# =============================================================================
# リモートディレクトリ作成
# =============================================================================
ensure_remote_dir() {
    if [[ "$DRY_RUN" == true ]]; then
        log_info "DRY-RUN: リモートディレクトリ作成をスキップ"
        return 0
    fi

    local q_dir
    q_dir="$(shell_quote "$REMOTE_DIR")"

    log_info "リモートディレクトリ確認: $REMOTE_DIR"

    if ! "${SSH_CMD[@]}" "${REMOTE_USER}@${REMOTE_HOST}" "mkdir -p -- $q_dir"; then
        log_error "リモートディレクトリ作成に失敗しました: $REMOTE_DIR"
        return 1
    fi

    log_info "リモートディレクトリOK"
}

# =============================================================================
# syncモード（rsync差分）
# =============================================================================
run_sync() {
    log_info "syncモード開始"

    local opts=(-a -v -h --progress --partial --stats)
    if [[ "$DRY_RUN" == true ]]; then
        opts+=(--dry-run)
        log_info "DRY-RUN: 実際の転送は行われません"
    fi

    log_info "対象: $TARGET_DIR/"
    log_info "送信先: ${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_DIR}/"

    if ! rsync "${opts[@]}" \
        -e "$RSYNC_SSH_STR" \
        "$TARGET_DIR/" \
        "${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_DIR}/"; then
        log_error "rsync転送に失敗しました"
        return 1
    fi

    log_info "sync完了"
}

# =============================================================================
# archiveモード（tar.gz圧縮）
# =============================================================================
run_archive() {
    log_info "archiveモード開始"

    local name="backup_$(date '+%Y%m%d_%H%M%S').tar.gz"
    LOCAL_BACKUP="${TMPDIR:-/tmp}/${name}"

    local parent="$(dirname -- "$TARGET_DIR")"
    local base="$(basename -- "$TARGET_DIR")"

    if [[ "$DRY_RUN" == true ]]; then
        log_info "DRY-RUN: tar圧縮をスキップ"
        log_info "生成予定: $name"
        return 0
    fi

    log_info "圧縮中: $TARGET_DIR → $LOCAL_BACKUP"

    if ! tar --numeric-owner -czf "$LOCAL_BACKUP" -C "$parent" -- "$base" 2>>"$LOG_FILE"; then
        log_error "tar圧縮に失敗しました"
        return 1
    fi

    local size
    size="$(du -h "$LOCAL_BACKUP" | awk '{print $1}')"
    log_info "圧縮完了: $LOCAL_BACKUP ($size)"

    local sha_local
    sha_local="$(sha256sum "$LOCAL_BACKUP" | awk '{print $1}')"
    log_info "SHA-256: $sha_local"

    log_info "転送中: ${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_DIR}/"

    if ! rsync -avh --progress --partial \
        -e "$RSYNC_SSH_STR" \
        "$LOCAL_BACKUP" \
        "${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_DIR}/"; then
        log_error "archive転送に失敗しました"
        log_warn "圧縮済みのローカルバックアップは削除せず保持します"
        KEEP_LOCAL_BACKUP=true
        return 1
    fi

    log_info "転送完了"

    # リモートSHA-256確認
    log_info "リモートSHA-256確認中"

    local q_remote
    q_remote="$(shell_quote "${REMOTE_DIR}/${name}")"

    local sha_remote
    sha_remote="$( \
        "${SSH_CMD[@]}" "${REMOTE_USER}@${REMOTE_HOST}" \
            "sha256sum -- $q_remote 2>/dev/null | awk '{print \$1}'" || printf ''
    )"

    sha_remote="$(printf '%s\n' "$sha_remote" | awk 'NR==1{print $1}')"

    if [[ -z "$sha_remote" ]]; then
        log_error "リモートSHA-256取得に失敗しました"
        log_warn "整合性を確認できないため、ローカルバックアップは保持します"
        KEEP_LOCAL_BACKUP=true
        return 1
    fi

    if [[ "$sha_local" == "$sha_remote" ]]; then
        log_info "SHA-256一致 OK"
    else
        log_error "SHA-256不一致！"
        log_error "  ローカル: $sha_local"
        log_error "  リモート: $sha_remote"
        log_warn "転送データが破損している可能性があるため、ローカルバックアップは保持します"
        KEEP_LOCAL_BACKUP=true
        return 1
    fi

    log_info "archive完了: $name"
}

# =============================================================================
# メイン
# =============================================================================
main() {
    parse_args "$@"

    # ログファイルディレクトリ作成
    mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true

    log_info "=========================================="
    log_info "$SCRIPT_NAME v$VERSION 起動"
    log_info "=========================================="
    log_info "対象      : $TARGET_DIR"
    log_info "送信先    : ${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_DIR}"
    log_info "モード    : $MODE"
    log_info "SSHポート : $SSH_PORT"
    log_info "SSH鍵     : ${SSH_KEY:-デフォルト}"
    log_info "DRY-RUN   : $DRY_RUN"
    log_info "ログ      : $LOG_FILE"
    log_info "=========================================="

    check_dependencies
    build_ssh_command
    acquire_lock

    test_ssh_connection || exit 1
    ensure_remote_dir || exit 1

    case "$MODE" in
        sync)
            run_sync || exit 1
            ;;
        archive)
            run_archive || exit 1
            ;;
        *)
            log_error "内部エラー: 不明なモード $MODE"
            exit 1
            ;;
    esac

    log_info "=========================================="
    log_info "バックアップ成功！"
    log_info "=========================================="
}

# =============================================================================
# エントリーポイント
# =============================================================================
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
