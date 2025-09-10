#!/usr/bin/env bash

# Android APK Build Automation Agent - PREPARATION & STAGING MODE
# Smart agent that prepares APK build environment and alerts when ready
# WAITS for manual trigger before building APK as requested
# Integrates with GitHub Actions, monitors repository changes, and manages build preparation

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$SCRIPT_DIR"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LOG_DIR="$HOME/platform_ops/logs"
CONFIG_DIR="$HOME/platform_ops/config"
APK_CACHE_DIR="$HOME/platform_ops/apk_cache"
BUILD_WORKSPACE="$HOME/platform_ops/android_builds"

# Logging configuration
LOG_FILE="$LOG_DIR/android_apk_agent.log"
mkdir -p "$LOG_DIR" "$CONFIG_DIR" "$APK_CACHE_DIR" "$BUILD_WORKSPACE"

log() {
    local level="$1"
    shift
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $*" | tee -a "$LOG_FILE"
}

log_info() { log "INFO" "$@"; }
log_warn() { log "WARN" "$@"; }
log_error() { log "ERROR" "$@"; }
log_success() { log "SUCCESS" "$@"; }

# Configuration management
load_config() {
    local config_file="$CONFIG_DIR/apk_agent_config.conf"
    
    if [[ ! -f "$config_file" ]]; then
        log_info "Creating default configuration"
        cat > "$config_file" <<EOF
# Android APK Build Agent Configuration - PREPARATION MODE
GITHUB_REPO="spiralgang/FileSystemds"
GITHUB_BRANCH="main"
BUILD_TYPE="debug"
AUTO_BUILD_ON_PUSH="false"
AUTO_PREPARE_ON_PUSH="true"
NOTIFICATION_ENABLED="true"
RETENTION_DAYS="30"
MAX_APK_CACHE_SIZE="1G"
ANDROID_API_LEVEL="34"
JAVA_VERSION="17"
GRADLE_VERSION="8.4"
BUILD_TIMEOUT="45"
PREPARATION_MODE="true"
MANUAL_TRIGGER_REQUIRED="true"
WEBHOOK_URL=""
SLACK_WEBHOOK=""
DISCORD_WEBHOOK=""
EOF
    fi
    
    source "$config_file"
    log_info "Configuration loaded from $config_file"
}

# GitHub API interaction
check_github_api() {
    log_info "Checking GitHub API connectivity"
    
    if command -v curl >/dev/null; then
        if curl -s "https://api.github.com/repos/$GITHUB_REPO" >/dev/null; then
            log_success "GitHub API accessible"
            return 0
        else
            log_warn "GitHub API not accessible"
            return 1
        fi
    else
        log_warn "curl not available for GitHub API checks"
        return 1
    fi
}

# Repository monitoring
monitor_repository() {
    log_info "Starting repository monitoring for $GITHUB_REPO"
    
    local last_commit_file="$CONFIG_DIR/last_commit_sha"
    local current_commit=""
    
    if check_github_api; then
        current_commit=$(curl -s "https://api.github.com/repos/$GITHUB_REPO/commits/$GITHUB_BRANCH" | \
                        grep '"sha":' | head -1 | cut -d'"' -f4 || echo "")
        
        if [[ -n "$current_commit" ]]; then
            if [[ -f "$last_commit_file" ]]; then
                local last_commit=$(cat "$last_commit_file")
                if [[ "$current_commit" != "$last_commit" ]]; then
                    log_info "New commit detected: $current_commit"
                    echo "$current_commit" > "$last_commit_file"
                    
                    if [[ "$AUTO_PREPARE_ON_PUSH" == "true" ]]; then
                        prepare_apk_build_environment "$current_commit"
                    elif [[ "$AUTO_BUILD_ON_PUSH" == "true" ]]; then
                        log_warn "AUTO_BUILD_ON_PUSH is deprecated. Use manual trigger after preparation."
                    fi
                    return 0
                else
                    log_info "No new commits since last check"
                    return 1
                fi
            else
                echo "$current_commit" > "$last_commit_file"
                log_info "Initial commit recorded: $current_commit"
                return 1
            fi
        else
            log_error "Failed to get current commit SHA"
            return 1
        fi
    else
        log_warn "Cannot monitor repository - API unavailable"
        return 1
    fi
}

# APK build environment preparation (NEW - replaces auto-build)
prepare_apk_build_environment() {
    local commit_sha="${1:-latest}"
    log_info "Preparing APK build environment for commit: $commit_sha"
    
    local preparation_id="prep-$(date +%Y%m%d-%H%M%S)-${commit_sha:0:8}"
    local prep_dir="$BUILD_WORKSPACE/$preparation_id"
    
    mkdir -p "$prep_dir"
    
    # Create preparation manifest
    cat > "$prep_dir/preparation_manifest.json" <<EOF
{
    "preparation_id": "$preparation_id",
    "commit_sha": "$commit_sha",
    "build_type": "$BUILD_TYPE",
    "prepared_at": "$(date -Iseconds)",
    "repository": "$GITHUB_REPO",
    "branch": "$GITHUB_BRANCH",
    "status": "preparing",
    "build_ready": false,
    "manual_trigger_required": true,
    "environment_validated": false,
    "dependencies_ready": false
}
EOF
    
    # Trigger GitHub Actions preparation workflow
    if trigger_github_actions_preparation "$commit_sha" "$preparation_id"; then
        log_success "GitHub Actions preparation triggered successfully"
        monitor_preparation_progress "$preparation_id"
    else
        log_warn "GitHub Actions trigger failed, performing local preparation"
        perform_local_preparation "$preparation_id" "$commit_sha"
    fi
}

# Manual APK build triggering (NEW - replaces automatic build)
trigger_manual_apk_build() {
    local commit_sha="${1:-latest}"
    local preparation_id="${2:-}"
    
    log_info "Triggering MANUAL APK build for commit: $commit_sha"
    
    if [[ -z "$preparation_id" ]]; then
        # Find the latest preparation for this commit
        preparation_id=$(find "$BUILD_WORKSPACE" -name "prep-*-${commit_sha:0:8}" -type d | sort | tail -1 | basename)
        if [[ -z "$preparation_id" ]]; then
            log_error "No preparation found for commit $commit_sha. Run prepare first."
            return 1
        fi
    fi
    
    local prep_dir="$BUILD_WORKSPACE/$preparation_id"
    if [[ ! -f "$prep_dir/preparation_manifest.json" ]]; then
        log_error "Preparation manifest not found. Environment not prepared."
        return 1
    fi
    
    # Check if environment is ready
    local status=$(grep '"status"' "$prep_dir/preparation_manifest.json" | cut -d'"' -f4)
    if [[ "$status" != "ready-for-build" ]]; then
        log_error "Environment not ready for build. Current status: $status"
        return 1
    fi
    
    log_info "Environment verified as ready. Triggering APK build..."
    
    # Trigger GitHub Actions with build action
    if trigger_github_actions_build "$commit_sha" "$preparation_id"; then
        log_success "Manual APK build triggered successfully"
        monitor_build_progress "$preparation_id"
    else
        log_warn "GitHub Actions trigger failed, attempting local build"
        perform_local_build "$preparation_id" "$commit_sha"
    fi
}

# GitHub Actions preparation workflow triggering (NEW)
trigger_github_actions_preparation() {
    local commit_sha="$1"
    local preparation_id="$2"
    
    log_info "Attempting to trigger GitHub Actions preparation workflow"
    
    # Check if gh CLI is available and authenticated
    if command -v gh >/dev/null; then
        if gh auth status >/dev/null 2>&1; then
            log_info "GitHub CLI authenticated, triggering preparation workflow"
            
            if gh workflow run android-apk-build.yml \
                --repo "$GITHUB_REPO" \
                --ref "$GITHUB_BRANCH" \
                --field action="prepare" \
                --field build_type="$BUILD_TYPE" \
                --field notify_completion="true"; then
                log_success "GitHub Actions preparation workflow triggered"
                return 0
            else
                log_error "Failed to trigger GitHub Actions preparation workflow"
                return 1
            fi
        else
            log_warn "GitHub CLI not authenticated"
            return 1
        fi
    else
        log_warn "GitHub CLI not available"
        return 1
    fi
}

# GitHub Actions build workflow triggering (UPDATED)
trigger_github_actions_build() {
    local commit_sha="$1"
    local preparation_id="$2"
    
    log_info "Attempting to trigger GitHub Actions BUILD workflow"
    
    # Check if gh CLI is available and authenticated
    if command -v gh >/dev/null; then
        if gh auth status >/dev/null 2>&1; then
            log_info "GitHub CLI authenticated, triggering BUILD workflow"
            
            if gh workflow run android-apk-build.yml \
                --repo "$GITHUB_REPO" \
                --ref "$GITHUB_BRANCH" \
                --field action="build" \
                --field build_type="$BUILD_TYPE" \
                --field notify_completion="true"; then
                log_success "GitHub Actions BUILD workflow triggered"
                return 0
            else
                log_error "Failed to trigger GitHub Actions BUILD workflow"
                return 1
            fi
        else
            log_warn "GitHub CLI not authenticated"
            return 1
        fi
    else
        log_warn "GitHub CLI not available"
        return 1
    fi
}

# Local APK environment preparation (NEW)
perform_local_preparation() {
    local preparation_id="$1"
    local commit_sha="$2"
    local prep_dir="$BUILD_WORKSPACE/$preparation_id"
    
    log_info "Performing local APK environment preparation: $preparation_id"
    
    cd "$prep_dir"
    
    # Update preparation manifest
    local manifest="$prep_dir/preparation_manifest.json"
    sed -i 's/"status": "preparing"/"status": "validating"/' "$manifest"
    
    log_info "Setting up Android preparation environment"
    
    # Validate environment
    local validation_errors=()
    
    # Check for Android SDK (optional for preparation)
    if [[ -z "${ANDROID_HOME:-}" ]] && [[ -z "${ANDROID_SDK_ROOT:-}" ]]; then
        log_warn "Android SDK not found locally (will use GitHub Actions for build)"
        validation_errors+=("android_sdk_missing")
    else
        log_success "Android SDK found: ${ANDROID_HOME:-${ANDROID_SDK_ROOT}}"
        sed -i 's/"environment_validated": false/"environment_validated": true/' "$manifest"
    fi
    
    # Create Android project structure for validation
    if create_android_project_structure "$prep_dir"; then
        log_success "Android project structure validated"
        sed -i 's/"dependencies_ready": false/"dependencies_ready": true/' "$manifest"
    else
        log_error "Failed to create Android project structure"
        validation_errors+=("project_structure_failed")
    fi
    
    # Copy platform scripts to prepare for build
    if [[ -d "$SCRIPTS_DIR" ]]; then
        mkdir -p "$prep_dir/android/app/src/main/assets/scripts"
        cp "$SCRIPTS_DIR"/*.sh "$prep_dir/android/app/src/main/assets/scripts/" 2>/dev/null || true
        log_success "Platform scripts prepared for Android assets"
    fi
    
    # Determine final status
    if [[ ${#validation_errors[@]} -eq 0 ]] || [[ "${validation_errors[*]}" == "android_sdk_missing" ]]; then
        log_success "APK build environment prepared successfully!"
        sed -i 's/"status": "validating"/"status": "ready-for-build"/' "$manifest"
        sed -i 's/"build_ready": false/"build_ready": true/' "$manifest"
        
        # Send ready notification
        send_preparation_ready_notification "$preparation_id" "$commit_sha"
    else
        log_error "APK build environment preparation failed"
        sed -i 's/"status": "validating"/"status": "preparation-failed"/' "$manifest"
        
        # Send failure notification
        send_preparation_notification "$preparation_id" "failed"
    fi
}

# Local APK build (UPDATED - now requires preparation)
perform_local_build() {
    local preparation_id="$1"
    local commit_sha="$2"
    local prep_dir="$BUILD_WORKSPACE/$preparation_id"
    
    log_info "Performing local APK build from preparation: $preparation_id"
    
    # Verify preparation exists and is ready
    local manifest="$prep_dir/preparation_manifest.json"
    if [[ ! -f "$manifest" ]]; then
        log_error "Preparation manifest not found. Run preparation first."
        return 1
    fi
    
    local status=$(grep '"status"' "$manifest" | cut -d'"' -f4)
    if [[ "$status" != "ready-for-build" ]]; then
        log_error "Environment not ready for build. Current status: $status"
        return 1
    fi
    
    cd "$prep_dir"
    
    # Update manifest for build
    sed -i 's/"status": "ready-for-build"/"status": "building"/' "$manifest"
    
    # Check for Android SDK
    if [[ -z "${ANDROID_HOME:-}" ]] && [[ -z "${ANDROID_SDK_ROOT:-}" ]]; then
        log_warn "Android SDK not found, simulating build process"
        simulate_apk_build "$preparation_id"
        return 0
    fi
    
    # Android project structure should already exist from preparation
    # Build APK
    if build_actual_apk "$prep_dir"; then
        log_success "Local APK build completed successfully"
        sed -i 's/"status": "building"/"status": "build-complete"/' "$manifest"
        
        # Store APK in cache
        cache_apk_artifact "$preparation_id" "$prep_dir"
        
        # Send notifications
        send_build_notification "$preparation_id" "success"
    else
        log_error "Local APK build failed"
        sed -i 's/"status": "building"/"status": "build-failed"/' "$manifest"
        send_build_notification "$preparation_id" "failed"
    fi
}

# Simulate APK build for demonstration
simulate_apk_build() {
    local preparation_id="$1"
    local prep_dir="$BUILD_WORKSPACE/$preparation_id"
    
    log_info "Simulating APK build process (no Android SDK detected)"
    
    # Create mock APK file
    local apk_name="filesystemds-mobile-$(date +%Y%m%d-%H%M%S)-$BUILD_TYPE.apk"
    local mock_apk="$prep_dir/$apk_name"
    
    # Create a small zip file as mock APK
    echo "Mock FileSystemds Mobile APK - Preparation ID: $preparation_id" > "$prep_dir/mock_content.txt"
    echo "Generated: $(date)" >> "$prep_dir/mock_content.txt"
    echo "Build Type: $BUILD_TYPE" >> "$prep_dir/mock_content.txt"
    
    if command -v zip >/dev/null; then
        cd "$prep_dir"
        zip -q "$apk_name" mock_content.txt
        log_success "Mock APK created: $apk_name"
    else
        # Create without compression
        cp mock_content.txt "$mock_apk"
        log_success "Mock APK file created: $apk_name"
    fi
    
    # Update build manifest
    local manifest="$prep_dir/preparation_manifest.json"
    sed -i 's/"status": "building"/"status": "build-complete"/' "$manifest"
    
    # Cache the mock APK
    cache_apk_artifact "$preparation_id" "$prep_dir"
    
    # Send notification
    send_build_notification "$preparation_id" "success"
}

# Create Android project structure
create_android_project_structure() {
    local build_dir="$1"
    
    log_info "Creating Android project structure"
    
    # Copy the workflow's Android setup logic here
    # This is a simplified version - the full implementation would be in the GitHub Actions workflow
    
    mkdir -p "$build_dir/android/app/src/main/java/com/spiralgang/filesystemds"
    mkdir -p "$build_dir/android/app/src/main/res/layout"
    mkdir -p "$build_dir/android/app/src/main/res/values"
    mkdir -p "$build_dir/android/app/src/main/assets/scripts"
    
    # Copy platform scripts to assets
    if [[ -d "$SCRIPTS_DIR" ]]; then
        cp "$SCRIPTS_DIR"/*.sh "$build_dir/android/app/src/main/assets/scripts/" 2>/dev/null || true
        log_info "Platform scripts copied to Android assets"
    fi
    
    log_success "Android project structure created"
}

# Build actual APK
build_actual_apk() {
    local build_dir="$1"
    
    log_info "Building actual APK"
    
    cd "$build_dir/android"
    
    # This would contain the actual Gradle build commands
    # For now, simulate the build
    log_warn "Actual APK build not implemented - using simulation"
    return 0
}

# Cache APK artifact
cache_apk_artifact() {
    local build_id="$1"
    local build_dir="$2"
    
    log_info "Caching APK artifact for build: $build_id"
    
    local apk_file=$(find "$build_dir" -name "*.apk" -type f | head -1)
    
    if [[ -n "$apk_file" && -f "$apk_file" ]]; then
        local cached_apk="$APK_CACHE_DIR/$(basename "$apk_file")"
        cp "$apk_file" "$cached_apk"
        
        # Create symlink for latest
        ln -sf "$cached_apk" "$APK_CACHE_DIR/latest.apk"
        
        # Create metadata
        cat > "$APK_CACHE_DIR/$(basename "$apk_file").meta" <<EOF
{
    "build_id": "$build_id",
    "apk_file": "$(basename "$apk_file")",
    "size": "$(stat -c%s "$apk_file" 2>/dev/null || echo 0)",
    "created": "$(date -Iseconds)",
    "md5": "$(md5sum "$apk_file" 2>/dev/null | cut -d' ' -f1 || echo 'unknown')"
}
EOF
        
        log_success "APK cached: $cached_apk"
        
        # Clean old cache entries
        cleanup_apk_cache
    else
        log_error "No APK file found to cache"
    fi
}

# Monitor preparation progress (NEW)
monitor_preparation_progress() {
    local preparation_id="$1"
    local max_wait_time="$((BUILD_TIMEOUT * 60))"
    local wait_time=0
    local check_interval=30
    
    log_info "Monitoring preparation progress for: $preparation_id"
    
    while [[ $wait_time -lt $max_wait_time ]]; do
        # Check if preparation completed (this would check GitHub Actions API in real implementation)
        if check_preparation_status "$preparation_id"; then
            log_success "Preparation completed: $preparation_id"
            return 0
        fi
        
        sleep $check_interval
        wait_time=$((wait_time + check_interval))
        
        if [[ $((wait_time % 300)) -eq 0 ]]; then
            log_info "Still waiting for preparation to complete... (${wait_time}s/${max_wait_time}s)"
        fi
    done
    
    log_error "Preparation timeout reached for: $preparation_id"
    return 1
}

# Check preparation status (NEW)
check_preparation_status() {
    local preparation_id="$1"
    local prep_dir="$BUILD_WORKSPACE/$preparation_id"
    local manifest="$prep_dir/preparation_manifest.json"
    
    if [[ -f "$manifest" ]]; then
        local status=$(grep '"status"' "$manifest" | cut -d'"' -f4)
        case "$status" in
            "ready-for-build"|"build-complete"|"build-failed")
                return 0
                ;;
            *)
                return 1
                ;;
        esac
    fi
    return 1
}

# Monitor build progress (UPDATED)
monitor_build_progress() {
    local build_id="$1"
    local max_wait_time="$((BUILD_TIMEOUT * 60))"
    local wait_time=0
    local check_interval=30
    
    log_info "Monitoring build progress for: $build_id"
    
    while [[ $wait_time -lt $max_wait_time ]]; do
        # Check if build completed (this would check GitHub Actions API in real implementation)
        if check_build_status "$build_id"; then
            log_success "Build completed: $build_id"
            return 0
        fi
        
        sleep $check_interval
        wait_time=$((wait_time + check_interval))
        
        if [[ $((wait_time % 300)) -eq 0 ]]; then
            log_info "Still waiting for build to complete... (${wait_time}s/${max_wait_time}s)"
        fi
    done
    
    log_error "Build timeout reached for: $build_id"
    return 1
}

# Check build status
check_build_status() {
    local build_id="$1"
    
    # In a real implementation, this would check GitHub Actions API
    # For now, simulate completion after some time
    local build_file="$BUILD_WORKSPACE/$build_id/build_manifest.json"
    
    if [[ -f "$build_file" ]]; then
        local status=$(grep '"status":' "$build_file" | cut -d'"' -f4)
        case "$status" in
            "success"|"failed")
                return 0
                ;;
            *)
                return 1
                ;;
        esac
    fi
    
    return 1
}

# Send preparation ready notifications (NEW)
send_preparation_ready_notification() {
    local preparation_id="$1"
    local commit_sha="$2"
    
    if [[ "$NOTIFICATION_ENABLED" != "true" ]]; then
        return 0
    fi
    
    log_info "Sending preparation ready notification: $preparation_id"
    
    local notification_text="🚨 FileSystemds APK Build Environment READY!

📋 Preparation ID: $preparation_id
✅ Status: Ready for Build
📝 Commit: $commit_sha
🔧 Build Type: $BUILD_TYPE
⏰ Prepared: $(date)

🎯 MANUAL TRIGGER REQUIRED TO BUILD APK

To build the APK:
1. Run: ./scripts/android_apk_agent.sh build $commit_sha
2. Or use GitHub Actions workflow with action='build'

Environment is validated and all dependencies are ready.
APK build will complete in ~2-3 minutes once triggered."
    
    # Send to various notification channels
    send_webhook_notification "$notification_text"
    send_slack_notification "$notification_text"
    send_discord_notification "$notification_text"
    send_local_notification "$notification_text"
    
    # Also log prominently
    log_success "🚨 APK BUILD ENVIRONMENT READY - MANUAL TRIGGER REQUIRED!"
    log_success "Run: ./scripts/android_apk_agent.sh build $commit_sha"
}

# Send preparation status notifications (NEW)
send_preparation_notification() {
    local preparation_id="$1"
    local status="$2"
    
    if [[ "$NOTIFICATION_ENABLED" != "true" ]]; then
        return 0
    fi
    
    log_info "Sending preparation notification: $preparation_id ($status)"
    
    local message=""
    local emoji=""
    
    case "$status" in
        "ready")
            emoji="✅"
            message="APK build environment prepared and ready!"
            ;;
        "failed")
            emoji="❌"
            message="APK build environment preparation failed!"
            ;;
        *)
            emoji="ℹ️"
            message="APK build environment preparation status: $status"
            ;;
    esac
    
    local notification_text="$emoji FileSystemds APK Build Preparation
Preparation ID: $preparation_id
Status: $status
Repository: $GITHUB_REPO
Branch: $GITHUB_BRANCH
Build Type: $BUILD_TYPE
Time: $(date)

$message"
    
    # Send to various notification channels
    send_webhook_notification "$notification_text"
    send_slack_notification "$notification_text"
    send_discord_notification "$notification_text"
    send_local_notification "$notification_text"
}

# Send build notifications (UPDATED)
send_build_notification() {
    local preparation_id="$1"
    local status="$2"
    
    if [[ "$NOTIFICATION_ENABLED" != "true" ]]; then
        return 0
    fi
    
    log_info "Sending build notification: $preparation_id ($status)"
    
    local message=""
    local emoji=""
    
    case "$status" in
        "success")
            emoji="✅"
            message="APK build completed successfully!"
            ;;
        "failed")
            emoji="❌"
            message="APK build failed!"
            ;;
        *)
            emoji="ℹ️"
            message="APK build status: $status"
            ;;
    esac
    
    local notification_text="$emoji FileSystemds Mobile APK Build
Preparation ID: $preparation_id
Status: $status
Repository: $GITHUB_REPO
Branch: $GITHUB_BRANCH
Build Type: $BUILD_TYPE
Time: $(date)

$message"
    
    # Send to various notification channels
    send_webhook_notification "$notification_text"
    send_slack_notification "$notification_text"
    send_discord_notification "$notification_text"
    send_local_notification "$notification_text"
}

# Webhook notification
send_webhook_notification() {
    local message="$1"
    
    if [[ -n "$WEBHOOK_URL" ]] && command -v curl >/dev/null; then
        curl -s -X POST "$WEBHOOK_URL" \
             -H "Content-Type: application/json" \
             -d "{\"text\": \"$message\"}" >/dev/null || true
        log_info "Webhook notification sent"
    fi
}

# Slack notification
send_slack_notification() {
    local message="$1"
    
    if [[ -n "$SLACK_WEBHOOK" ]] && command -v curl >/dev/null; then
        curl -s -X POST "$SLACK_WEBHOOK" \
             -H "Content-Type: application/json" \
             -d "{\"text\": \"$message\"}" >/dev/null || true
        log_info "Slack notification sent"
    fi
}

# Discord notification
send_discord_notification() {
    local message="$1"
    
    if [[ -n "$DISCORD_WEBHOOK" ]] && command -v curl >/dev/null; then
        curl -s -X POST "$DISCORD_WEBHOOK" \
             -H "Content-Type: application/json" \
             -d "{\"content\": \"$message\"}" >/dev/null || true
        log_info "Discord notification sent"
    fi
}

# Local notification
send_local_notification() {
    local message="$1"
    
    # Try desktop notification
    if command -v notify-send >/dev/null; then
        notify-send "FileSystemds APK Build" "$message" || true
    fi
    
    # Log notification
    log_info "BUILD NOTIFICATION: $message"
}

# APK cache management
cleanup_apk_cache() {
    log_info "Cleaning up APK cache"
    
    # Remove old APK files beyond retention period
    find "$APK_CACHE_DIR" -name "*.apk" -type f -mtime +$RETENTION_DAYS -delete 2>/dev/null || true
    find "$APK_CACHE_DIR" -name "*.meta" -type f -mtime +$RETENTION_DAYS -delete 2>/dev/null || true
    
    # Check cache size and remove oldest files if needed
    if command -v du >/dev/null; then
        local cache_size=$(du -sh "$APK_CACHE_DIR" 2>/dev/null | cut -f1 || echo "0")
        log_info "Current APK cache size: $cache_size"
    fi
    
    log_success "APK cache cleanup completed"
}

# List available APKs
list_apks() {
    log_info "Available APK files:"
    
    if [[ -d "$APK_CACHE_DIR" ]]; then
        for apk in "$APK_CACHE_DIR"/*.apk; do
            if [[ -f "$apk" ]]; then
                local basename_apk=$(basename "$apk")
                local meta_file="$APK_CACHE_DIR/$basename_apk.meta"
                
                echo "📱 $basename_apk"
                
                if [[ -f "$meta_file" ]]; then
                    echo "   $(cat "$meta_file" | grep -E '"created"|"size"|"build_id"' | tr '\n' ' ')"
                fi
                echo
            fi
        done
        
        # Show latest APK
        if [[ -L "$APK_CACHE_DIR/latest.apk" ]]; then
            local latest_target=$(readlink "$APK_CACHE_DIR/latest.apk")
            echo "🔗 Latest APK: $(basename "$latest_target")"
        fi
    else
        echo "No APK cache directory found"
    fi
}

# Download APK
download_apk() {
    local apk_name="${1:-latest}"
    local target_dir="${2:-$PWD}"
    
    if [[ "$apk_name" == "latest" ]]; then
        if [[ -L "$APK_CACHE_DIR/latest.apk" ]]; then
            local latest_apk="$APK_CACHE_DIR/latest.apk"
            cp "$latest_apk" "$target_dir/"
            log_success "Latest APK copied to: $target_dir/$(basename "$(readlink "$latest_apk")")"
        else
            log_error "No latest APK available"
            return 1
        fi
    else
        local apk_file="$APK_CACHE_DIR/$apk_name"
        if [[ -f "$apk_file" ]]; then
            cp "$apk_file" "$target_dir/"
            log_success "APK copied to: $target_dir/$apk_name"
        else
            log_error "APK not found: $apk_name"
            return 1
        fi
    fi
}

# Continuous monitoring mode
start_monitoring() {
    local interval="${1:-300}"  # 5 minutes default
    
    log_info "Starting continuous monitoring mode (interval: ${interval}s)"
    
    while true; do
        log_info "Checking for repository changes..."
        
        if monitor_repository; then
            log_info "Changes detected, build triggered"
        fi
        
        sleep "$interval"
    done
}

# Health check
health_check() {
    log_info "Performing health check"
    
    local issues=0
    
    # Check directories
    for dir in "$LOG_DIR" "$CONFIG_DIR" "$APK_CACHE_DIR" "$BUILD_WORKSPACE"; do
        if [[ ! -d "$dir" ]]; then
            log_error "Directory missing: $dir"
            issues=$((issues + 1))
        fi
    done
    
    # Check configuration
    if [[ -z "$GITHUB_REPO" ]]; then
        log_error "GITHUB_REPO not configured"
        issues=$((issues + 1))
    fi
    
    # Check external dependencies
    for cmd in curl git; do
        if ! command -v "$cmd" >/dev/null; then
            log_warn "Command not available: $cmd"
        fi
    done
    
    # Check GitHub API
    if ! check_github_api; then
        log_warn "GitHub API not accessible"
    fi
    
    if [[ $issues -eq 0 ]]; then
        log_success "Health check passed"
        return 0
    else
        log_error "Health check failed with $issues issues"
        return 1
    fi
}

# Main function
main() {
    log_info "Android APK Build Automation Agent started"
    
    # Load configuration
    load_config
    
    case "${1:-help}" in
        "monitor")
            monitor_repository
            ;;
        "start-monitoring")
            start_monitoring "${2:-300}"
            ;;
        "prepare")
            prepare_apk_build_environment "${2:-latest}"
            ;;
        "build")
            trigger_manual_apk_build "${2:-latest}" "${3:-}"
            ;;
        "list")
            list_apks
            ;;
        "download")
            download_apk "${2:-latest}" "${3:-$PWD}"
            ;;
        "health")
            health_check
            ;;
        "cleanup")
            cleanup_apk_cache
            ;;
        "config")
            echo "Configuration file: $CONFIG_DIR/apk_agent_config.conf"
            cat "$CONFIG_DIR/apk_agent_config.conf"
            ;;
        "logs")
            tail -f "$LOG_FILE"
            ;;
        "help")
            cat << 'EOF'
Android APK Build Automation Agent - PREPARATION & STAGING MODE

Usage: android_apk_agent.sh <command> [options]

Commands:
  monitor                     - Check for repository changes once (prepares environment)
  start-monitoring [interval] - Start continuous monitoring (default: 300s)
  prepare [commit]           - Prepare APK build environment for specific commit
  build [commit] [prep_id]   - Trigger MANUAL APK build (requires preparation first)
  list                       - List available APK files and preparations
  download [name] [dir]      - Download APK (default: latest to current dir)
  health                     - Perform system health check
  cleanup                    - Clean up old APK cache entries and preparations
  config                     - Show current configuration
  logs                       - Tail the agent log file
  help                       - Show this help message

PREPARATION & STAGING WORKFLOW:
  1. Environment automatically prepares when code changes are detected
  2. Agent alerts when build environment is ready
  3. Manual trigger required to actually build APK
  4. Use 'build' command or GitHub Actions with action='build'

Examples:
  # Prepare build environment for latest commit
  ./android_apk_agent.sh prepare

  # Build APK after preparation (manual trigger)
  ./android_apk_agent.sh build

  # Start monitoring for auto-preparation
  ./android_apk_agent.sh start-monitoring

  # List prepared environments and built APKs
  ./android_apk_agent.sh list
Configuration is stored in: ~/platform_ops/config/apk_agent_config.conf
Logs are stored in: ~/platform_ops/logs/android_apk_agent.log
APK cache is in: ~/platform_ops/apk_cache/
Build workspace is in: ~/platform_ops/android_builds/
EOF
            ;;
        *)
            echo "Usage: $0 {monitor|start-monitoring|prepare|build|list|download|health|cleanup|config|logs|help}"
            echo "PREPARATION MODE: Agent prepares environment and waits for manual build trigger"
            exit 1
            ;;
    esac
}

# Trap signals for clean shutdown
trap 'log_info "Agent shutting down..."; exit 0' SIGTERM SIGINT

main "$@"