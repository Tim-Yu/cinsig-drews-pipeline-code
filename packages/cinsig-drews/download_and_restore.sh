#!/usr/bin/env bash

set -euo pipefail

# Restore from GitHub raw branch files only.
# No release assets used.

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

OWNER="Tim-Yu"
REPO="cinsig-drews-pipeline-code"
BRANCH="main"
PACKAGE_PATH="packages/cinsig-drews/v1.0-hg38-r3"
DEST_DIR="./cinsig-drews"
WORK_DIR=""
CALLER_PWD="$(pwd)"

usage() {
    cat <<EOF
Usage:
  bash download_and_restore.sh [options]

Options:
  --owner <name>         GitHub owner/org (default: $OWNER)
  --repo <name>          GitHub repo (default: $REPO)
  --branch <name>        Branch (default: $BRANCH)
  --package-path <path>  Repo path to payload version (default: $PACKAGE_PATH)
  --dest <dir>           Restore destination (default: $DEST_DIR)
  --work-dir <dir>       Temp work dir (default: mktemp)

This script downloads only via raw URLs:
  https://github.com/<owner>/<repo>/raw/refs/heads/<branch>/<package-path>/...
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --owner) OWNER="$2"; shift 2 ;;
        --repo) REPO="$2"; shift 2 ;;
        --branch) BRANCH="$2"; shift 2 ;;
        --package-path) PACKAGE_PATH="$2"; shift 2 ;;
        --dest) DEST_DIR="$2"; shift 2 ;;
        --work-dir) WORK_DIR="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *)
            echo -e "${RED}Unknown option: $1${NC}" >&2
            usage
            exit 1
            ;;
    esac
done

# Resolve destination path before changing directories.
if [[ "$DEST_DIR" != /* ]]; then
    DEST_DIR="$CALLER_PWD/$DEST_DIR"
fi

for cmd in wget sha256sum tar cat sort awk; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo -e "${RED}Missing command: $cmd${NC}" >&2
        exit 1
    fi
done

if [[ -z "$WORK_DIR" ]]; then
    WORK_DIR="$(mktemp -d)"
else
    mkdir -p "$WORK_DIR"
fi
WORK_DIR="$(cd "$WORK_DIR" && pwd)"
LOG_FILE="$WORK_DIR/restore.log"
RAW_BASE="https://github.com/${OWNER}/${REPO}/raw/refs/heads/${BRANCH}/${PACKAGE_PATH}"

cleanup() {
    echo "Temporary work dir kept at: $WORK_DIR" >> "$LOG_FILE"
}
trap cleanup EXIT

{
    echo "============================================================"
    echo "Restore CINSig from GitHub raw"
    echo "Started: $(date -u '+%Y-%m-%d %H:%M:%SZ')"
    echo "Raw base: $RAW_BASE"
    echo "Destination: $DEST_DIR"
    echo "Work dir: $WORK_DIR"
    echo "============================================================"
} | tee "$LOG_FILE"

cd "$WORK_DIR"

echo -e "${BLUE}[1/6] Downloading manifest metadata...${NC}" | tee -a "$LOG_FILE"
wget -q "$RAW_BASE/MANIFEST.tsv" -O MANIFEST.tsv
wget -q "$RAW_BASE/CHECKSUMS.sha256" -O CHECKSUMS.sha256
wget -q "$RAW_BASE/REQUIRED_FILES.txt" -O REQUIRED_FILES.txt

echo -e "${BLUE}[2/6] Downloading split parts from raw URLs...${NC}" | tee -a "$LOG_FILE"
awk 'NR>1 {print $1}' MANIFEST.tsv | while read -r fname; do
    [[ -z "$fname" ]] && continue
    echo "Downloading $fname" | tee -a "$LOG_FILE"
    wget -q "$RAW_BASE/$fname" -O "$fname"
done

echo -e "${BLUE}[3/6] Verifying checksums...${NC}" | tee -a "$LOG_FILE"
sha256sum -c CHECKSUMS.sha256 | tee -a "$LOG_FILE"

echo -e "${BLUE}[4/6] Reassembling payload files...${NC}" | tee -a "$LOG_FILE"
cat $(ls code_payload.part-* | LC_ALL=C sort) > code_payload.tar.gz
cat $(ls cinsig-drews-cpu.sif.part-* | LC_ALL=C sort) > cinsig-drews-cpu.sif

echo -e "${BLUE}[5/6] Extracting code and installing .sif...${NC}" | tee -a "$LOG_FILE"
mkdir -p "$DEST_DIR"
tar -xzf code_payload.tar.gz -C "$DEST_DIR"
cp cinsig-drews-cpu.sif "$DEST_DIR/cinsig-drews-cpu.sif"

echo -e "${BLUE}[6/6] Validating restored files...${NC}" | tee -a "$LOG_FILE"
missing=0
while read -r rel; do
    [[ -z "$rel" ]] && continue
    if [[ ! -e "$DEST_DIR/$rel" ]]; then
        echo -e "${RED}Missing required file: $DEST_DIR/$rel${NC}" | tee -a "$LOG_FILE"
        missing=1
    fi
done < REQUIRED_FILES.txt

# Explicit checks that must exist for hg38/hg19 operation
for ref in \
    "app/third_party/drews_compendium/Section 5 Robustness analysis/Section 5.2 Signature stability across genomic technologies/input/Data_preparation/refgenome/hg19.chrom.sizes.txt" \
    "app/third_party/drews_compendium/Section 5 Robustness analysis/Section 5.2 Signature stability across genomic technologies/input/Data_preparation/refgenome/gap_hg19.txt" \
    "app/third_party/drews_compendium/Section 5 Robustness analysis/Section 5.2 Signature stability across genomic technologies/input/Data_preparation/refgenome/hg38.chrom.sizes.txt" \
    "app/third_party/drews_compendium/Section 5 Robustness analysis/Section 5.2 Signature stability across genomic technologies/input/Data_preparation/refgenome/gap_hg38.txt"
do
    if [[ ! -f "$DEST_DIR/$ref" ]]; then
        echo -e "${RED}Missing ref file: $DEST_DIR/$ref${NC}" | tee -a "$LOG_FILE"
        missing=1
    fi
done

if [[ ! -f "$DEST_DIR/scripts/run_full_workflow.sh" ]]; then
    echo -e "${RED}Missing workflow launcher: $DEST_DIR/scripts/run_full_workflow.sh${NC}" | tee -a "$LOG_FILE"
    missing=1
fi
if [[ ! -f "$DEST_DIR/app/scripts/run_drews_pipeline.sh" ]]; then
    echo -e "${RED}Missing app pipeline script: $DEST_DIR/app/scripts/run_drews_pipeline.sh${NC}" | tee -a "$LOG_FILE"
    missing=1
fi
if [[ ! -f "$DEST_DIR/cinsig-drews-cpu.sif" ]]; then
    echo -e "${RED}Missing sif: $DEST_DIR/cinsig-drews-cpu.sif${NC}" | tee -a "$LOG_FILE"
    missing=1
fi

if [[ "$missing" -ne 0 ]]; then
    echo -e "${RED}Restore failed validation. See log: $LOG_FILE${NC}" | tee -a "$LOG_FILE"
    exit 1
fi

chmod +x "$DEST_DIR/scripts/run_full_workflow.sh" "$DEST_DIR/app/scripts/run_drews_pipeline.sh" || true

echo -e "${GREEN}Restore completed successfully.${NC}" | tee -a "$LOG_FILE"
echo "Run in destination:" | tee -a "$LOG_FILE"
echo "  cd $DEST_DIR" | tee -a "$LOG_FILE"
echo "  bash scripts/run_full_workflow.sh --help" | tee -a "$LOG_FILE"
echo "  bash scripts/run_full_workflow.sh --cn-dir ./data --outdir ./output --file-pattern '_gapfilled_LogR_new\\.txt$' --build hg38" | tee -a "$LOG_FILE"
