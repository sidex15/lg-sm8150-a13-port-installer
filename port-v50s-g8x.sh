#!/usr/bin/env bash
#=========================================================================
#   LG V50S ThinQ / G8X ThinQ (mh2lm) - Android 13 Port
#   port-v50s-g8x.sh - the TWRP installer, run on partition images
#
#   Builds flash-ready images on a PC from a dump of the phone's stock A12
#   partitions, instead of patching the phone from TWRP. Every stage mirrors
#   META-INF/com/google/android/update-binary of the V50s port:
#
#     vendor.img   stock vendor patched in place: build.prop, fstab,
#                  immvibed, global sound effect. The port's own vendor.img
#                  is never used, same as the zip.
#     system.img   A13 system with the stock device identity restored
#     product.img  A13 product with the stock device identity restored
#                  and the mh2lm display overlay
#     OP.img       stock OP with the VoLTE / VoWiFi patch (LM-V510N only)
#     vbmeta.img   the port's vbmeta
#
#   The port's own volte.sh runs unmodified in a chroot under busybox (with
#   GNU sed, see setup_env). The stock dumps are only ever read; every write
#   goes to a copy in the output folder.
#
#   Needs Linux or WSL2, root (for loop mounts), e2fsprogs, python3,
#   a static busybox and unzip. See README.md.
#=========================================================================

BOARD=mh2lm
DEVICE="LG V50S / G8X ThinQ"
OTHER_BOARD=flashlmdd
OTHER_DEVICE="LG V50"
OTHER_SCRIPT=port-v50.sh
DEFAULT_OUT=out-v50s-g8x

# the VoLTE / VoWiFi OP patch is only for the Korean V50S
VOLTE_MODEL=LM-V510N

SELF=$(basename "$0")
export LC_ALL=C DEBUGFS_PAGER=__none__ PAGER=__none__
umask 022

TMP=""
WORK=""
MNT=""
ROOT=""
STOCK=""
LOG=""
OUT_STARTED=0

# Props that carry the device identity. Matches the per-partition variants
# (ro.product.system.model, ro.system_ext.build.id, ...) as well as the
# bare ones (ro.product.model, ro.build.id). Deliberately does NOT match
# ro.build.version.* - the A13 version props must survive untouched.
PROP_RE='^ro\.product\.([a-z_0-9]+\.)?(brand|device|manufacturer|model|name)=|^ro\.([a-z_0-9]+\.)?build\.(date\.utc|date|fingerprint|id)='

#-------------------------------------------------------------------------
# output helpers
#-------------------------------------------------------------------------

ui_print() {
  printf '%s\n' "$1"
  [ -n "$LOG" ] && printf '%s\n' "$1" >>"$LOG"
}

umount_dir() {
  [ -n "$1" ] && [ -d "$1" ] || return 0
  grep -q " $1 " /proc/mounts 2>/dev/null || return 0
  umount "$1" 2>/dev/null || umount -l "$1" 2>/dev/null
}

cleanup() {
  [ -n "$TMP" ] || return 0
  umount_dir "$MNT/system"
  umount_dir "$MNT/product"
  umount_dir "$MNT/vendor"
  umount_dir "$ROOT/OP"
  rm -rf "$TMP"
  TMP=""
}

OUT_FILES="vbmeta.img system.img product.img vendor.img OP.img FLASH.txt"

# remove_outputs - only ever the files this script writes
remove_outputs() {
  for f in $OUT_FILES; do rm -f "$OUT/$f"; done
}

abort() {
  ui_print " "
  ui_print "!!! $1"
  if [ "$OUT_STARTED" -eq 1 ] && ls "$OUT"/*.img >/dev/null 2>&1; then
    # half-patched images must never be mistaken for finished ones
    remove_outputs
    ui_print "!!! The unfinished images were removed from $OUT"
  fi
  ui_print "!!! Nothing was flashed and the stock dumps were not modified."
  ui_print " "
  cleanup
  exit 1
}

trap cleanup EXIT
trap 'abort "Interrupted."' INT TERM

usage() {
  cat <<EOF
Usage: sudo ./$SELF --port <zip|folder> --stock <dump folder> [options]

Builds flash-ready Android 13 images for the $DEVICE ($BOARD)
from a dump of its stock A12 partitions.

  --port PATH           the A13 port: its flashable zip, or the unpacked folder
  --stock DIR           folder holding the stock dumps (system_a.bin, vendor_a.bin, ...)
  --slot a|b            slot to read from the dumps and to flash to
                        (default: the active slot recorded in gpt_main*.bin)
  --system FILE         use this stock system image instead of the one in --stock
  --product FILE        same, for product
  --vendor FILE         same, for vendor
  --op FILE             same, for OP
  --out DIR             output folder (default: ./$DEFAULT_OUT)
  --encryption fbe|none /data encryption written into the vendor fstab
                        (default: ask; fbe when there is no terminal)
  --soundfx dts|ais     global sound effect on the audio mixer
                        (default: ask; dts when there is no terminal)
  --force               write into an output folder that already holds images
  -h, --help            show this text

Windows paths such as F:\\edl\\dumps are accepted when run under WSL.
This script is for $BOARD only; the LG V50 ($OTHER_BOARD) has $OTHER_SCRIPT.
EOF
}

#-------------------------------------------------------------------------
# environment
#-------------------------------------------------------------------------

# host_path <path> - Windows paths become WSL paths
host_path() {
  case "$1" in
    [A-Za-z]:[\\/]*)
      if command -v wslpath >/dev/null 2>&1; then
        wslpath -u "$1"
        return
      fi
      ;;
  esac
  printf '%s\n' "$1"
}

# SELinux helpers. The host kernel has no SELinux, so files created on a loop
# mount come out unlabelled; TWRP would have labelled them. These put the
# labels in the ext4 xattr directly, the same bytes Android's tools write.
write_helper() {
  cat >"$TMP/helper.py" <<'EOF'
import glob, os, struct, sys

XA = 'security.selinux'

def label(p):
    try:
        return os.getxattr(p, XA, follow_symlinks=False)
    except OSError:
        return None

def entries(root):
    # top-down, so a new folder is labelled before anything inside it
    yield root
    for d, dirs, files in os.walk(root):
        dirs.sort()
        for n in dirs + sorted(files):
            yield os.path.join(d, n)

def unlabeled(root):
    for p in entries(root):
        if label(p) is None:
            print(os.path.relpath(p, root))

# Gives every unlabelled entry that was not unlabelled before the patch its
# folder's context - what the kernel does for a new file under TWRP.
def inherit(root, before):
    with open(before) as f:
        skip = set(f.read().splitlines())
    for p in entries(root):
        rel = os.path.relpath(p, root)
        if rel in skip or label(p) is not None:
            continue
        ctx = label(os.path.dirname(p))
        if ctx is None:
            print('%s <parent unlabelled, left alone>' % rel)
            continue
        os.setxattr(p, XA, ctx, follow_symlinks=False)
        print('%s %s' % (rel, ctx.rstrip(b'\0').decode()))

def setlabel(p, ctx):
    os.setxattr(p, XA, ctx.encode() + b'\0', follow_symlinks=False)

# Active slot from the GPT dumps: Qualcomm keeps it in bit 50 of each
# A/B partition's attribute field.
def slot(d):
    active = {}
    for f in sorted(glob.glob(os.path.join(d, 'gpt_main*.bin'))):
        with open(f, 'rb') as fh:
            data = fh.read()
        for ss in (4096, 512):
            if data[ss:ss + 8] == b'EFI PART':
                break
        else:
            continue
        lba, n, esz = struct.unpack_from('<QII', data, ss + 72)
        for i in range(n):
            e = data[lba * ss + i * esz:lba * ss + (i + 1) * esz]
            if len(e) < 128:
                break
            name = e[56:128].decode('utf-16-le', 'replace').split('\0')[0]
            active[name] = (struct.unpack_from('<Q', e, 48)[0] >> 50) & 1
    for base in ('system', 'boot'):
        a, b = active.get(base + '_a'), active.get(base + '_b')
        if a is not None and b is not None and a != b:
            print('a' if a else 'b')
            return 0
    return 1

cmd = sys.argv[1]
if cmd == 'unlabeled':
    unlabeled(sys.argv[2])
elif cmd == 'inherit':
    inherit(sys.argv[2], sys.argv[3])
elif cmd == 'set':
    setlabel(sys.argv[2], sys.argv[3])
elif cmd == 'slot':
    sys.exit(slot(sys.argv[2]))
EOF
}

setup_env() {
  [ "$(id -u)" -eq 0 ] || abort "Run as root: loop-mounting the images needs it (sudo ./$SELF ...)."

  [ -e /sys/fs/selinux/enforce ] && abort "This host runs SELinux, which would relabel every file written into the images. Use WSL2 or a Debian/Ubuntu machine."

  missing=""
  for t in debugfs e2fsck tune2fs mount umount chroot ldd python3 unzip awk sed grep od dd md5sum; do
    command -v "$t" >/dev/null 2>&1 || missing="$missing $t"
  done
  [ -z "$missing" ] || abort "Missing tools:$missing (Debian/Ubuntu: apt install e2fsprogs python3 unzip busybox-static)"
  [ "$(printf 'a' | sed -z 's/$/b/' 2>/dev/null)" = "ab" ] || abort "sed on this host has no -z option; GNU sed is needed."

  BUSYBOX=${BUSYBOX:-$(command -v busybox)}
  [ -n "$BUSYBOX" ] && [ -x "$BUSYBOX" ] || abort "busybox not found (Debian/Ubuntu: apt install busybox-static)."

  TMP=$(mktemp -d /tmp/a13port.XXXXXX) || abort "Could not create a temp folder."
  WORK=$TMP/work.tmp
  MNT=$TMP/mnt
  ROOT=$TMP/root
  STOCK=$TMP/stockprops
  mkdir -p "$MNT" "$STOCK" "$ROOT/bin" "$ROOT/OP"
  write_helper

  # volte.sh runs in a chroot under busybox, as under TWRP, so busybox has
  # to be a static build. One applet is swapped out: sed is GNU sed. Every
  # append line in volte.sh is "sed -i -z ...", and busybox sed has no -z -
  # not even the osm0sis 1.30.1 build in the zip, which makes TWRP skip
  # those lines. GNU sed applies them as volte.sh intends.
  cp "$BUSYBOX" "$ROOT/bin/busybox" && chmod 0755 "$ROOT/bin/busybox"
  chroot "$ROOT" /bin/busybox --install -s /bin >/dev/null 2>&1 && [ -x "$ROOT/bin/sh" ] \
    || abort "$BUSYBOX will not run in a chroot - it must be a static build (apt install busybox-static, or set BUSYBOX=/path/to/static/busybox)."
  chroot_add "$(command -v sed)" /bin/sed \
    && [ "$(printf 'a' | chroot "$ROOT" /bin/sed -z 's/$/b/' 2>/dev/null)" = "ab" ] \
    || abort "Could not set up GNU sed inside the chroot."
  mkdir -p "$ROOT/dev"
  mknod -m 0666 "$ROOT/dev/null" c 1 3 2>/dev/null || : >"$ROOT/dev/null"
}

# chroot_add <host binary> <path in the chroot> - with the libraries it links
chroot_add() {
  rm -f "$ROOT$2"
  cp -L "$1" "$ROOT$2" || return 1
  for lib in $(ldd "$1" 2>/dev/null | awk '{ for (i = 1; i <= NF; i++) if ($i ~ /^\//) print $i }'); do
    mkdir -p "$ROOT$(dirname "$lib")" && cp -L "$lib" "$ROOT$lib" || return 1
  done
}

#-------------------------------------------------------------------------
# port access - the flashable zip or its unpacked folder, same entry names
#-------------------------------------------------------------------------

PORT_ZIP=0

port_has() {
  if [ "$PORT_ZIP" -eq 1 ]; then
    unzip -l "$PORT" "$1" >/dev/null 2>&1
  else
    [ -f "$PORT/$1" ]
  fi
}

port_cat() {
  if [ "$PORT_ZIP" -eq 1 ]; then
    unzip -p "$PORT" "$1"
  else
    cat "$PORT/$1"
  fi
}

port_size() {
  if [ "$PORT_ZIP" -eq 1 ]; then
    unzip -l "$PORT" "$1" 2>/dev/null | awk 'NR == 4 { print $1 }'
  else
    stat -c %s "$PORT/$1"
  fi
}

# port_extract_dir <prefix> <dest> - every entry under <prefix>/ into <dest>/<prefix>/
port_extract_dir() {
  if [ "$PORT_ZIP" -eq 1 ]; then
    unzip -o -qq "$PORT" "$1/*" -d "$2" >/dev/null 2>&1 || return 1
  else
    [ -d "$PORT/$1" ] || return 1
    mkdir -p "$2" && cp -r "$PORT/$1" "$2/" || return 1
  fi
  # TWRP extracts with umask 022 and the zip carries no Unix modes, so
  # everything lands 0644/0755 whatever the source filesystem says
  find "$2/$1" -type d -exec chmod 0755 {} + && find "$2/$1" -type f -exec chmod 0644 {} +
}

#-------------------------------------------------------------------------
# image helpers
#-------------------------------------------------------------------------

# img_cat <image> <path> - a file out of an ext4 image, read-only, no mount
img_cat() {
  debugfs -R "cat \"$2\"" "$1" 2>/dev/null
}

img_has() {
  debugfs -R "stat \"$2\"" "$1" 2>/dev/null | grep -q '^Inode:'
}

# img_first <image> <path>... - echo the first path that exists in the image
img_first() {
  _img=$1
  shift
  for p in "$@"; do
    img_has "$_img" "$p" && { echo "$p"; return 0; }
  done
  return 1
}

# check_ext4 <image> <label> - must be a raw ext4 image, not sparse
check_ext4() {
  [ -f "$1" ] || abort "$2 not found: $1"
  magic=$(od -An -tx1 -j0 -N4 "$1" | tr -d ' \n')
  [ "$magic" = "3aff26ed" ] && abort "$2 is an Android sparse image, convert it first: simg2img $1 $1.raw"
  magic=$(od -An -tx1 -j1080 -N2 "$1" | tr -d ' \n')
  [ "$magic" = "53ef" ] || abort "$2 has no ext4 superblock: $1 (an empty slot? check --slot)"
}

# write_stream <dest> - stdin into <dest>, with progress on a terminal
write_stream() {
  if [ -t 2 ]; then
    dd of="$1" bs=16M iflag=fullblock status=progress
  else
    dd of="$1" bs=16M iflag=fullblock status=none
  fi
}

# copy_image <source> <dest> <label>
copy_image() {
  ui_print " - Copying $3 ($(( $(stat -c %s "$1") / 1048576 )) MiB) to $(basename "$2")"
  write_stream "$2" <"$1" || abort "Failed to copy $3."
  [ "$(stat -c %s "$2")" = "$(stat -c %s "$1")" ] || abort "$(basename "$2") came out the wrong size."
  fsck_baseline "$2"
}

# mounted_rw <mountpoint> - true if /proc/mounts says the fs itself is rw
mounted_rw() {
  awk -v m="$1" '$2 == m && $4 ~ /(^|,)rw(,|$)/ { found = 1 } END { exit !found }' /proc/mounts
}

# mount_img <image> <mountpoint>
# Mounts read-write. Images built with the ext4 read-only feature refuse a rw
# mount; clearing that flag rescues the ones with no genuinely shared blocks.
mount_img() {
  mkdir -p "$2"
  umount_dir "$2"
  _err=$(mount -t ext4 -o loop,rw "$1" "$2" 2>&1) || { ui_print " - mount: $_err"; return 1; }
  mounted_rw "$2" && return 0

  ui_print " - $(basename "$1") came up read-only, trying to unlock it..."
  umount_dir "$2"
  tune2fs -O ^read-only "$1" >/dev/null 2>&1
  _err=$(mount -t ext4 -o loop,rw "$1" "$2" 2>&1) || { ui_print " - mount: $_err"; return 1; }
  mounted_rw "$2" || return 1
  ui_print " - $(basename "$1") unlocked"
  return 0
}

# fsck_issues <image> - what e2fsck -n finds, minus its progress chatter.
# -n opens the image read-only and answers no to every fix.
fsck_issues() {
  e2fsck -fn "$1" 2>&1 | sed "s#$1#IMG#g" | awk '
    /^Pass [0-9]/ || /^e2fsck [0-9]/ || /files \(.*blocks$/ || /^$/ { next }
    /Filesystem still has errors/ { next }
    { print }'
}

# fsck_baseline <image> - findings before this script touched the image.
# The port's images already carry "Padding at end of inode bitmap is not
# set", a make_ext4fs quirk the kernel ignores; the baseline keeps that and
# anything like it from being reported as damage done here.
fsck_baseline() {
  fsck_issues "$1" >"$TMP/fsck.$(basename "$1")"
}

# writable_file <path> - true if this existing file can really be written.
# Opens for append and writes nothing, so the file is left byte-for-byte alone.
writable_file() {
  [ -f "$1" ] || return 1
  ( : >>"$1" ) 2>/dev/null || return 1
  return 0
}

# echo the first path in the list that exists
first_existing() {
  for f in "$@"; do
    [ -f "$f" ] && { echo "$f"; return 0; }
  done
  return 1
}

sel_set() {
  python3 "$TMP/helper.py" set "$1" "$2" 2>/dev/null
}

# label_snapshot <mountpoint> / label_new_files <mountpoint> - see write_helper
label_snapshot() {
  python3 "$TMP/helper.py" unlabeled "$1" >"$TMP/unlabeled.$(basename "$1")" \
    || abort "Could not read SELinux labels under $1."
}

label_new_files() {
  python3 "$TMP/helper.py" inherit "$1" "$TMP/unlabeled.$(basename "$1")" >"$TMP/labelled" \
    || abort "Could not write SELinux labels under $1."
  n=$(awk 'END { print NR }' "$TMP/labelled")
  sed 's/^/     label /' "$TMP/labelled" >>"$LOG"
  ui_print " - labels      : $n new file(s) given their folder's SELinux context"
}

#-------------------------------------------------------------------------
# build.prop helpers
#
# Every write goes through "cat >existing_file" rather than cp/mv so the
# original inode, mode and SELinux context are preserved.
#-------------------------------------------------------------------------

# prop_set <file> <key> <value> - replaces the key or appends it
prop_set() {
  awk -v k="$2" -v v="$3" '
    { i = index($0, "=")
      if (i > 0 && substr($0, 1, i-1) == k) {
        if (!done) { print k "=" v; done = 1 }
        next
      }
      print
    }
    END { if (!done) print k "=" v }
  ' "$1" >"$WORK" || return 1
  [ -s "$WORK" ] || return 1
  cat "$WORK" >"$1" || return 1
  rm -f "$WORK"
}

# prop_get <file> <key>
prop_get() {
  grep -m1 "^$2=" "$1" 2>/dev/null | cut -d= -f2-
}

# save_props <stock build.prop> <output file> - echoes how many were saved
save_props() {
  grep -E "$PROP_RE" "$1" >"$2" 2>/dev/null
  # awk, not wc -l: counts a final line even when it has no trailing newline
  awk 'END { print NR }' "$2"
}

# merge_props <saved props file> <target build.prop>
# Replaces matching keys in place; appends any that the A13 file lacks.
merge_props() {
  awk '
    NR == FNR {
      i = index($0, "=")
      if (i > 0) { k = substr($0, 1, i-1); P[k] = substr($0, i+1); ORD[++n] = k }
      next
    }
    { i = index($0, "=")
      if (i > 0) {
        k = substr($0, 1, i-1)
        if (k in P) { print k "=" P[k]; SEEN[k] = 1; next }
      }
      print
    }
    END {
      for (i = 1; i <= n; i++) {
        k = ORD[i]
        if (!(k in SEEN)) {
          if (!hdr) { print ""; print "# Stock device properties restored by the A13 port installer"; hdr = 1 }
          print k "=" P[k]
        }
      }
    }
  ' "$1" "$2" >"$WORK" || return 1
  [ -s "$WORK" ] || return 1
  cat "$WORK" >"$2" || return 1
  rm -f "$WORK"
}

#-------------------------------------------------------------------------
# inputs
#-------------------------------------------------------------------------

PORT=""
STOCK_DIR=""
SLOT=""
SLOT_FROM=""
OUT=""
ENC_OPT=""
AFX_OPT=""
FORCE=0
IMG_SYSTEM=""
IMG_PRODUCT=""
IMG_VENDOR=""
IMG_OP=""

parse_args() {
  [ $# -gt 0 ] || { usage; exit 1; }
  while [ $# -gt 0 ]; do
    case "$1" in
      --port)       PORT=$(host_path "$2");        shift 2 ;;
      --stock)      STOCK_DIR=$(host_path "$2");   shift 2 ;;
      --slot)       SLOT=$2;                       shift 2 ;;
      --system)     IMG_SYSTEM=$(host_path "$2");  shift 2 ;;
      --product)    IMG_PRODUCT=$(host_path "$2"); shift 2 ;;
      --vendor)     IMG_VENDOR=$(host_path "$2");  shift 2 ;;
      --op)         IMG_OP=$(host_path "$2");      shift 2 ;;
      --out)        OUT=$(host_path "$2");         shift 2 ;;
      --encryption) ENC_OPT=$2;                    shift 2 ;;
      --soundfx)    AFX_OPT=$2;                    shift 2 ;;
      --force)      FORCE=1;                       shift ;;
      -h|--help)    usage; exit 0 ;;
      *)            usage >&2; echo >&2; abort "Unknown option: $1" ;;
    esac
  done

  case "$SLOT" in ""|a|b) ;; *) abort "--slot must be a or b." ;; esac
  case "$ENC_OPT" in ""|fbe|none) ;; *) abort "--encryption must be fbe or none." ;; esac
  case "$AFX_OPT" in ""|dts|ais) ;; *) abort "--soundfx must be dts or ais." ;; esac
  [ -n "$PORT" ] || abort "--port is required."
  [ -n "$STOCK_DIR" ] || [ -n "$IMG_SYSTEM" ] || abort "--stock is required (or --system/--product/--vendor/--op)."
  [ -n "$OUT" ] || OUT=$PWD/$DEFAULT_OUT
}

# stock_file <partition> - that partition's dump for $SLOT
stock_file() {
  [ -n "$STOCK_DIR" ] || return 1
  for n in "$1_$SLOT.bin" "$1_$SLOT.img" "$1.bin" "$1.img"; do
    [ -f "$STOCK_DIR/$n" ] && { echo "$STOCK_DIR/$n"; return 0; }
  done
  return 1
}

resolve_inputs() {
  ui_print "-- Checking inputs --"

  if [ -d "$PORT" ]; then
    PORT_ZIP=0
  elif [ -f "$PORT" ]; then
    unzip -l "$PORT" >/dev/null 2>&1 || abort "Not a zip file: $PORT"
    PORT_ZIP=1
  else
    abort "Port not found: $PORT"
  fi
  for e in system.img product.img vbmeta.img; do
    port_has "$e" || abort "$e is missing from the port."
  done
  ui_print " - Port        : $PORT"

  if [ -n "$STOCK_DIR" ]; then
    [ -d "$STOCK_DIR" ] || abort "Stock dump folder not found: $STOCK_DIR"
  fi
  if [ -z "$SLOT" ]; then
    if [ -n "$STOCK_DIR" ] && SLOT=$(python3 "$TMP/helper.py" slot "$STOCK_DIR"); then
      SLOT_FROM="active slot in the GPT dump"
    else
      SLOT=a
      SLOT_FROM="no GPT dump to read the active slot from, assumed"
    fi
  else
    SLOT_FROM="--slot"
  fi
  ui_print " - Slot        : $SLOT ($SLOT_FROM)"

  [ -n "$IMG_SYSTEM" ]  || IMG_SYSTEM=$(stock_file system)   || abort "No stock system dump for slot $SLOT in $STOCK_DIR"
  [ -n "$IMG_PRODUCT" ] || IMG_PRODUCT=$(stock_file product) || abort "No stock product dump for slot $SLOT in $STOCK_DIR"
  [ -n "$IMG_VENDOR" ]  || IMG_VENDOR=$(stock_file vendor)   || abort "No stock vendor dump for slot $SLOT in $STOCK_DIR"
  [ -n "$IMG_OP" ]      || IMG_OP=$(stock_file OP)           || IMG_OP=""

  check_ext4 "$IMG_SYSTEM" "Stock system"
  check_ext4 "$IMG_PRODUCT" "Stock product"
  check_ext4 "$IMG_VENDOR" "Stock vendor"
  [ -n "$IMG_OP" ] && check_ext4 "$IMG_OP" "Stock OP"
  ui_print " - system      : $IMG_SYSTEM"
  ui_print " - product     : $IMG_PRODUCT"
  ui_print " - vendor      : $IMG_VENDOR"
  ui_print " - OP          : ${IMG_OP:-none}"

  check_fits system.img "$IMG_SYSTEM"
  check_fits product.img "$IMG_PRODUCT"

  # never let an output land on top of an input
  mkdir -p "$OUT" || abort "Could not create $OUT"
  OUT=$(cd "$OUT" && pwd -P)
  if [ "$PORT_ZIP" -eq 0 ] && [ "$(cd "$PORT" && pwd -P)" = "$OUT" ]; then
    abort "--out is the port folder; its system.img and product.img would be overwritten. Pick another folder."
  fi
  for f in "$IMG_SYSTEM" "$IMG_PRODUCT" "$IMG_VENDOR" "$IMG_OP" "$PORT"; do
    [ -n "$f" ] && [ -f "$f" ] || continue
    [ "$(cd "$(dirname "$f")" && pwd -P)" = "$OUT" ] || continue
    case " $OUT_FILES " in
      *" $(basename "$f") "*) abort "--out would overwrite the input $f. Pick another folder." ;;
    esac
  done
  if [ "$FORCE" -eq 0 ]; then
    for f in $OUT_FILES; do
      [ -e "$OUT/$f" ] && abort "$OUT already holds $f. Pick an empty folder or pass --force."
    done
  fi
  ui_print " - Output      : $OUT"
  ui_print " "
}

# check_fits <port image> <stock dump>
# A dump is the whole partition, so its size is the partition size. An A13
# image bigger than that was built for another device.
check_fits() {
  need=$(port_size "$1")
  have=$(stat -c %s "$2")
  [ -n "$need" ] || abort "Could not read the size of $1 in the port."
  [ "$need" -le "$have" ] || abort "The port's $1 ($need bytes) is bigger than this phone's partition ($have bytes). Wrong port for this device?"
}

#-------------------------------------------------------------------------
# encryption choice
#-------------------------------------------------------------------------

FSTAB_FBE='/dev/block/bootdevice/by-name/userdata    /data    ext4    discard,nosuid,nodev,barrier=1,noatime,noauto_da_alloc,errors=continue,inlinecrypt    latemount,wait,check,formattable,fileencryption=aes-256-xts:aes-256-cts:v2+inlinecrypt_optimized,quota,reservedsize=128M'
FSTAB_RAW='/dev/block/bootdevice/by-name/userdata    /data    ext4    nosuid,nodev,barrier=1,noatime,noauto_da_alloc,errors=continue    latemount,wait,check,formattable,quota,reservedsize=128M'

ENC_MODE=""
FSTAB_LINE=""

choose_encryption() {
  case "$ENC_OPT" in
    fbe)  ENC_MODE="File-Based Encryption"; FSTAB_LINE="$FSTAB_FBE"; return ;;
    none) ENC_MODE="Unencrypted";           FSTAB_LINE="$FSTAB_RAW"; return ;;
  esac
  if [ ! -t 0 ]; then
    ENC_MODE="File-Based Encryption (defaulted, no terminal)"
    FSTAB_LINE="$FSTAB_FBE"
    return
  fi

  ui_print "Choose /data encryption for this install:"
  ui_print " "
  ui_print "   1 = File-Based Encryption  (recommended)"
  ui_print "   2 = Unencrypted            (less secure)"
  ui_print " "
  printf ' Choice [1]: '
  read -r ans
  case "$ans" in
    2) ENC_MODE="Unencrypted";           FSTAB_LINE="$FSTAB_RAW" ;;
    *) ENC_MODE="File-Based Encryption"; FSTAB_LINE="$FSTAB_FBE" ;;
  esac
  ui_print " - Selected: $ENC_MODE"
  ui_print " "
}

#-------------------------------------------------------------------------
# global sound effect choice
#-------------------------------------------------------------------------
#
# Android 13 gives AudioFlinger exactly one global effect slot on the audio
# mixer. LG's A13 builds fill it with AI Sound ("LG 3D Sound Engine"); the
# DTS Eagle engine that A11/A12 used there was dropped. Both engines exist on
# this hardware, so the slot can host either - but only one at a time.
#
#   dts : libeagle.so is patched so DTS Eagle claims the mixer slot, and
#         libeaglecore.so is patched so LG's A13 op_* parameter IDs land on
#         Eagle's handlers. DTS then processes every app.
#   ais : LG's AI Sound engine is installed and claims the slot instead,
#         which is what LG's own A13 does.
#
# Either way DTS:X keeps working on compress-offload playback through the
# vendor HAL, a separate path that bypasses the mixer.
#
# Like the V50s installer, the DTS swap here does not check the md5 of the
# stock libraries first.

AFX_MODE=""
AFX_NAME=""

choose_audio_effect() {
  case "$AFX_OPT" in
    dts) AFX_MODE="dts"; AFX_NAME="DTS:X on every app"; return ;;
    ais) AFX_MODE="ais"; AFX_NAME="LG 3D Sound Engine"; return ;;
  esac
  if [ ! -t 0 ]; then
    AFX_MODE="dts"
    AFX_NAME="DTS:X on every app (defaulted, no terminal)"
    return
  fi

  ui_print "Choose the global sound effect:"
  ui_print " "
  ui_print "   1 = DTS:X on every app"
  ui_print "       DTS Eagle runs on the audio mixer, so it"
  ui_print "       processes YouTube, Spotify, games - all of it."
  ui_print "       Use the LG 3D Sound Engine toggle to control it."
  ui_print " "
  ui_print "   2 = LG 3D Sound Engine   (stock A13 behaviour)"
  ui_print "       LG AI Sound takes the mixer slot instead."
  ui_print "       DTS:X then only affects offloaded local music."
  ui_print " "
  printf ' Choice [1]: '
  read -r ans
  case "$ans" in
    2) AFX_MODE="ais"; AFX_NAME="LG 3D Sound Engine" ;;
    *) AFX_MODE="dts"; AFX_NAME="DTS:X on every app" ;;
  esac
  ui_print " - Selected: $AFX_NAME"
  ui_print " "
}

# afx_install <port entry> <path under /vendor> <context for newly created files>
# Overwrites in place when the target exists so mode and context are inherited.
afx_install() {
  port_has "$1" || return 1
  _dst="$MNT/vendor/$2"
  _dir=$(dirname "$_dst")
  [ -d "$_dir" ] || mkdir -p "$_dir" || return 1
  _new=1
  if [ -f "$_dst" ]; then
    _new=0
    [ -f "$_dst.a12bak" ] || cat "$_dst" >"$_dst.a12bak" 2>/dev/null
  fi
  port_cat "$1" >"$_dst" || return 1
  [ -s "$_dst" ] || return 1
  chmod 0644 "$_dst"
  chown 0:0 "$_dst" 2>/dev/null
  [ "$_new" -eq 1 ] && sel_set "$_dst" "$3"
  return 0
}

# afx_swap <path under /vendor>
afx_swap() {
  _dst="$MNT/vendor/$1"
  [ -f "$_dst" ] || { ui_print " - sound fx    : $1 is missing"; return 1; }
  afx_install "audiofx/dts/vendor/$1" "$1" "u:object_r:vendor_file:s0"
}

# afx_restore <path under /vendor> - put the stock library back
afx_restore() {
  _dst="$MNT/vendor/$1"
  [ -f "$_dst.a12bak" ] || return 0
  cat "$_dst.a12bak" >"$_dst" 2>/dev/null || return 1
  chmod 0644 "$_dst"
  chown 0:0 "$_dst" 2>/dev/null
  return 0
}

AFX_LIBS="lib/soundfx/libeagle.so lib64/soundfx/libeagle.so lib/libeaglecore.so lib64/libeaglecore.so"

# runs with vendor.img already mounted read-write, from patch_vendor
patch_audio_effect() {
  AE="$MNT/vendor/etc/audio_effects.xml"
  if [ ! -f "$AE" ]; then
    ui_print " - sound fx    : audio_effects.xml not found, skipped"
    return
  fi
  [ -f "$AE.a12bak" ] || cat "$AE" >"$AE.a12bak" 2>/dev/null

  # Both modes need the framework speaking the A13 op_* key namespace, which is
  # what AudioFlinger intercepts and forwards to the mixer effect. Keeping the
  # dts feature on as well leaves the DTS:X menu and the offload path alive.
  prop_set "$vbp" "ro.vendor.lge.feature.global_effect_ais" "true" \
    || ui_print " - sound fx    : warning, could not set global_effect_ais"
  prop_set "$vbp" "ro.vendor.lge.feature.global_effect_dts" "true" \
    || ui_print " - sound fx    : warning, could not set global_effect_dts"

  if [ "$AFX_MODE" = "dts" ]; then
    ok=0
    afx_swap lib/soundfx/libeagle.so   && ok=$((ok + 1))
    afx_swap lib64/soundfx/libeagle.so && ok=$((ok + 1))
    afx_swap lib/libeaglecore.so       && ok=$((ok + 1))
    afx_swap lib64/libeaglecore.so     && ok=$((ok + 1))
    if [ "$ok" -lt 4 ]; then
      ui_print " - sound fx    : DTS swap incomplete ($ok/4), using LG AI Sound"
      for f in $AFX_LIBS; do afx_restore "$f"; done
      AFX_MODE="ais"
      AFX_NAME="LG 3D Sound Engine (vendor build not recognised for DTS)"
    fi
  fi

  n=0
  if [ "$AFX_MODE" = "ais" ]; then
    for f in $AFX_LIBS; do afx_restore "$f"; done
    for f in lib/soundfx/libaisound.so lib64/soundfx/libaisound.so \
             lib/libaise_core.so lib64/libaise_core.so; do
      afx_install "audiofx/ais/vendor/$f" "$f" "u:object_r:vendor_file:s0" \
        && n=$((n + 1))
    done
    for f in etc/aisound_tune.xml etc/upmix_model.tflite \
             etc/upmix_model.dlc etc/upmix_model_quantized.dlc; do
      afx_install "audiofx/ais/vendor/$f" "$f" "u:object_r:vendor_configs_file:s0" \
        && n=$((n + 1))
    done
  fi

  # drop any previous AI Sound registration, then add it back only for ais
  awk '!/aisound/' "$AE" >"$WORK" || abort "Failed to rewrite audio_effects.xml."
  [ -s "$WORK" ] || abort "audio_effects.xml came out empty."
  cat "$WORK" >"$AE"
  rm -f "$WORK"

  if [ "$AFX_MODE" = "ais" ]; then
    {
      printf '%s\n' '{ print }'
      printf '%s\n' '/<library name="eagle"/ && lib==0 { print "        <library name=\"aisound\" path=\"libaisound.so\"/>"; lib=1 }'
      printf '%s\n' '/<effect name="eagle_pipeline"/ && fx==0 { print "        <effect name=\"aisound_pipeline\" library=\"aisound\" uuid=\"e1abd756-97b7-11e9-bc42-526af7764f64\"/>"; fx=1 }'
    } >"$TMP/afx.awk"
    awk -f "$TMP/afx.awk" "$AE" >"$WORK" || abort "Failed to register AI Sound."
    [ -s "$WORK" ] || abort "audio_effects.xml came out empty."
    cat "$WORK" >"$AE"
    rm -f "$WORK" "$TMP/afx.awk"
    grep -q 'aisound_pipeline' "$AE" \
      || ui_print " - sound fx    : warning, AI Sound effect was not registered"
    ui_print " - sound fx    : LG AI Sound on the mixer ($n files)"
  else
    ui_print " - sound fx    : DTS Eagle on the mixer (4 libraries)"
  fi
}

#-------------------------------------------------------------------------
# stage 1 - save the stock device identity
#-------------------------------------------------------------------------

STOCK_MODEL=""
skip_volte=0

save_stock_props() {
  ui_print "-- Saving stock device properties --"

  # system-as-root images keep build.prop under <part>/system/
  SYS_BP=$(img_first "$IMG_SYSTEM" /system/build.prop /build.prop) || abort "Stock /system/build.prop not found."
  EXT_BP=$(img_first "$IMG_SYSTEM" /system/system_ext/etc/build.prop /system_ext/etc/build.prop)
  PRD_BP=$(img_first "$IMG_PRODUCT" /etc/build.prop) || abort "Stock /product/etc/build.prop not found."

  img_cat "$IMG_SYSTEM" "$SYS_BP" >"$STOCK/system.bp"
  img_cat "$IMG_PRODUCT" "$PRD_BP" >"$STOCK/product.bp"
  img_cat "$IMG_VENDOR" /build.prop >"$STOCK/vendor.bp"

  # this script's fixes are for one board; the other board has its own script
  sys_dev=$(prop_get "$STOCK/system.bp" ro.product.system.device)
  [ -n "$sys_dev" ] || sys_dev=$(prop_get "$STOCK/system.bp" ro.product.device)
  ven_dev=$(prop_get "$STOCK/vendor.bp" ro.product.vendor.device)
  for d in "$sys_dev" "$ven_dev"; do
    case "$d" in
      "$BOARD") ;;
      "$OTHER_BOARD") abort "These dumps are from a $OTHER_BOARD ($OTHER_DEVICE). Use $OTHER_SCRIPT for it." ;;
      *) abort "These dumps are from '${d:-unknown}', not $BOARD (system: ${sys_dev:-?}, vendor: ${ven_dev:-?})." ;;
    esac
  done

  n=$(save_props "$STOCK/system.bp" "$STOCK/system.prop")
  ui_print " - system      : $n props saved"
  [ "$n" -gt 0 ] || abort "No device props found in the stock /system/build.prop."

  if [ -n "$EXT_BP" ]; then
    img_cat "$IMG_SYSTEM" "$EXT_BP" >"$STOCK/system_ext.bp"
    n=$(save_props "$STOCK/system_ext.bp" "$STOCK/system_ext.prop")
    ui_print " - system_ext  : $n props saved"
  else
    ui_print " - system_ext  : not present on this device, skipped"
    : >"$STOCK/system_ext.prop"
  fi

  n=$(save_props "$STOCK/product.bp" "$STOCK/product.prop")
  ui_print " - product     : $n props saved"
  [ "$n" -gt 0 ] || abort "No device props found in the stock /product/etc/build.prop."

  STOCK_MODEL=$(grep -m1 -e '^ro\.product\.system\.model=' -e '^ro\.product\.model=' "$STOCK/system.prop" | cut -d= -f2-)
  [ -n "$STOCK_MODEL" ] && ui_print " - Detected    : $STOCK_MODEL ($sys_dev)"

  # the VoLTE/VoWiFi patch is only for the Korean variant
  if [ "$STOCK_MODEL" != "$VOLTE_MODEL" ]; then
    skip_volte=1
  fi

  # keep a copy next to the images so a bad flash can be fixed up by hand
  mkdir -p "$OUT/stock-props"
  cp -f "$STOCK"/system.prop "$STOCK"/system_ext.prop "$STOCK"/product.prop "$OUT/stock-props/" \
    && ui_print " - Backup copy written to $OUT/stock-props"
  ui_print " "
}

#-------------------------------------------------------------------------
# stage 2 - patch the stock vendor in place
#-------------------------------------------------------------------------

patch_vendor() {
  ui_print "-- Patching stock vendor for Android 13 --"

  copy_image "$IMG_VENDOR" "$OUT/vendor.img" "stock vendor"
  mount_img "$OUT/vendor.img" "$MNT/vendor" || abort "Could not mount vendor.img read-write."
  label_snapshot "$MNT/vendor"

  # 1. build.prop
  vbp="$MNT/vendor/build.prop"
  [ -f "$vbp" ] || abort "/vendor/build.prop not found."
  writable_file "$vbp" || abort "/vendor/build.prop is not writable."
  [ -f "$vbp.a12bak" ] || cat "$vbp" >"$vbp.a12bak" 2>/dev/null
  prop_set "$vbp" "ro.control_privapp_permissions" "disable" || abort "Failed to patch /vendor/build.prop."
  prop_set "$vbp" "ro.apex.updatable" "true" || abort "Failed to patch /vendor/build.prop."
  ui_print " - build.prop  : privapp permissions disabled, apex updatable"

  # 2. fstab - every fstab.<board> that carries a userdata entry
  patched=0
  for f in "$MNT/vendor"/etc/fstab.*; do
    [ -f "$f" ] || continue
    case "$f" in *.a12bak) continue ;; esac
    grep -q '^/dev/block/bootdevice/by-name/userdata' "$f" || continue

    [ -f "$f.a12bak" ] || cat "$f" >"$f.a12bak" 2>/dev/null
    awk -v line="$FSTAB_LINE" '
      index($0, "/dev/block/bootdevice/by-name/userdata") == 1 {
        if (!done) { print line; done = 1 }
        next
      }
      { print }
      END { if (!done) print line }
    ' "$f" >"$WORK" || abort "Failed to patch $(basename "$f")."
    [ -s "$WORK" ] || abort "Failed to patch $(basename "$f")."
    cat "$WORK" >"$f" || abort "Failed to write $(basename "$f")."
    rm -f "$WORK"
    ui_print " - $(basename "$f") : /data set to $ENC_MODE"
    patched=$((patched + 1))
  done
  [ "$patched" -gt 0 ] || abort "No fstab with a userdata entry found in /vendor/etc."

  # 3. immvibed - vibration fix
  if port_has "vendor/bin/immvibed"; then
    if [ -f "$MNT/vendor/bin/immvibed" ] && [ ! -f "$MNT/vendor/bin/immvibed.a12bak" ]; then
      cat "$MNT/vendor/bin/immvibed" >"$MNT/vendor/bin/immvibed.a12bak" 2>/dev/null
    fi
    # overwrite in place so mode + SELinux context are inherited
    port_cat "vendor/bin/immvibed" >"$MNT/vendor/bin/immvibed" || abort "Failed to write /vendor/bin/immvibed."
    [ -s "$MNT/vendor/bin/immvibed" ] || abort "/vendor/bin/immvibed came out empty."
    chmod 0755 "$MNT/vendor/bin/immvibed"
    chown 0:0 "$MNT/vendor/bin/immvibed" 2>/dev/null
    ui_print " - immvibed    : replaced (vibration fix)"
  fi

  # 4. global sound effect - DTS Eagle vs LG AI Sound on the mixer
  patch_audio_effect

  # the .a12bak backups are new files: label them as TWRP's kernel would
  label_new_files "$MNT/vendor"

  sync
  umount_dir "$MNT/vendor"
  ui_print " "
}

#-------------------------------------------------------------------------
# stage 3 - lay down the A13 images
#-------------------------------------------------------------------------

# stage_img <port entry> <output name>
stage_img() {
  ui_print " - Writing $1 ($(( $(port_size "$1") / 1048576 )) MiB)"
  ( set -o pipefail; port_cat "$1" | write_stream "$OUT/$2" ) || abort "Failed to write $2."
  [ "$(stat -c %s "$OUT/$2")" = "$(port_size "$1")" ] || abort "$2 came out the wrong size."
}

flash_images() {
  ui_print "-- Writing the Android 13 images --"
  stage_img "vbmeta.img"  "vbmeta.img"
  stage_img "system.img"  "system.img"
  stage_img "product.img" "product.img"
  check_ext4 "$OUT/system.img" "The port's system.img"
  check_ext4 "$OUT/product.img" "The port's product.img"
  fsck_baseline "$OUT/system.img"
  fsck_baseline "$OUT/product.img"
  ui_print " "
}

#-------------------------------------------------------------------------
# stage 4 - restore the stock device identity into the A13 images
#-------------------------------------------------------------------------

# restore_into <saved props> <target build.prop> <label>
restore_into() {
  writable_file "$2" || abort "Cannot write $3. The stock props are saved in $OUT/stock-props."
  merge_props "$1" "$2" || abort "Failed to restore props into $3."
  ui_print " - $3"
}

restore_stock_props() {
  ui_print "-- Restoring stock device properties --"

  mount_img "$OUT/system.img" "$MNT/system" || abort "The A13 system.img will not mount read-write."
  mount_img "$OUT/product.img" "$MNT/product" || abort "The A13 product.img will not mount read-write."

  bp=$(first_existing "$MNT/system/system/build.prop" "$MNT/system/build.prop") || abort "/system/build.prop not found in the A13 system image."
  restore_into "$STOCK/system.prop" "$bp" "/system/build.prop"

  if [ -s "$STOCK/system_ext.prop" ]; then
    bp=$(first_existing "$MNT/system/system/system_ext/etc/build.prop" "$MNT/system/system_ext/etc/build.prop")
    if [ -n "$bp" ]; then
      restore_into "$STOCK/system_ext.prop" "$bp" "/system/system_ext/etc/build.prop"
    else
      ui_print " - system_ext build.prop missing in the A13 image, skipped"
    fi
  fi

  bp=$(first_existing "$MNT/product/etc/build.prop") || abort "/product/etc/build.prop not found in the A13 product image."
  restore_into "$STOCK/product.prop" "$bp" "/product/etc/build.prop"

  sync
  umount_dir "$MNT/system"
  umount_dir "$MNT/product"
  ui_print " "
}

#-------------------------------------------------------------------------
# stage 5 - mh2lm display geometry
#
# product.img carries the V50 (flashlmdd) device overlay, and the V50 has a
# wide rectangular notch. On mh2lm that describes the wrong screen:
#
#                              V50 overlay        mh2lm hardware
#   config_mainBuiltInDisplayCutout   360x67px    156x76px teardrop
#   status_bar_height_portrait         67px        76px
#   rounded_corner_radius              84px       120px
#
# The overlay shipped with the port is that same APK with those three values
# set to the mh2lm ones (see tools/patch_arsc.py); everything else is untouched.
#-------------------------------------------------------------------------

OVERLAY_ENTRY=product/overlay/framework-res__auto_generated_rro_product.apk

patch_display_overlay() {
  ui_print "-- Correcting display cutout and status bar --"

  if ! port_has "$OVERLAY_ENTRY"; then
    ui_print " - Overlay not present in this port, skipped"
    ui_print " "
    return 0
  fi

  mount_img "$OUT/product.img" "$MNT/product" || abort "The A13 product.img will not mount read-write."

  target="$MNT/product/overlay/framework-res__auto_generated_rro_product.apk"
  writable_file "$target" || abort "Cannot write $target."

  # Written through "> existing_file" so the inode, mode and SELinux context
  # of the overlay the image shipped with are all preserved.
  port_cat "$OVERLAY_ENTRY" >"$target" || abort "Failed to write the display overlay."

  sync
  umount_dir "$MNT/product"
  ui_print " - Cutout      : 156x76px teardrop"
  ui_print " - Status bar  : 76px"
  ui_print " - Corners     : 120px radius"
  ui_print " "
}

#-------------------------------------------------------------------------
# stage 6 - OP partition (VoLTE / VoWiFi)
#
# TWRP mounts OP at /OP and runs volte.sh with busybox. Here OP.img is
# mounted at /OP inside a chroot that holds only a static busybox and GNU
# sed, and the port's volte.sh runs there unmodified - same paths, same
# applets apart from sed (see setup_env).
#-------------------------------------------------------------------------

OP_DONE=0

patch_op() {
  ui_print "-- Patching OP partition for VoLTE / VoWiFi --"

  if [ -z "$IMG_OP" ]; then
    ui_print " - No stock OP dump, skipped"
    ui_print " "
    return 0
  fi

  copy_image "$IMG_OP" "$OUT/OP.img" "stock OP"
  mount_img "$OUT/OP.img" "$ROOT/OP" || abort "Could not mount OP.img read-write."
  label_snapshot "$ROOT/OP"

  if port_has "volte/volte.sh"; then
    # CR-stripped only: a CRLF script will not run under busybox sh
    port_cat "volte/volte.sh" | tr -d '\r' >"$ROOT/volte.sh"
    chmod 0755 "$ROOT/volte.sh"
    printf '%s\n' "----- volte.sh -----" >>"$LOG"
    chroot "$ROOT" /bin/busybox env -i PATH=/bin /bin/busybox sh /volte.sh >>"$LOG" 2>&1
    printf '%s\n' "----- end volte.sh -----" >>"$LOG"
    rm -f "$ROOT/volte.sh"
  fi

  ui_print " - Copying OP config files..."
  rm -rf "$ROOT/op_extract"
  if port_extract_dir OP "$ROOT/op_extract"; then
    chroot "$ROOT" /bin/busybox cp -af /op_extract/OP/. /OP/ || abort "Failed to copy the OP config files."
  fi
  rm -rf "$ROOT/op_extract"

  label_new_files "$ROOT/OP"

  sync
  umount_dir "$ROOT/OP"
  OP_DONE=1
  ui_print " - VoLTE / VoWiFi patch finished"
  ui_print " "
}

#-------------------------------------------------------------------------
# stage 7 - check the results
#-------------------------------------------------------------------------

VERIFY_FAIL=0

# fsck_image <image> - fails on any e2fsck finding that is not in its baseline
fsck_image() {
  base="$TMP/fsck.$(basename "$1")"
  fsck_issues "$1" >"$TMP/fsck.after"
  new=$(grep -vxF -f "$base" "$TMP/fsck.after")
  old=$(awk 'END { print NR }' "$base")
  if [ -n "$new" ]; then
    ui_print " - e2fsck $(basename "$1") : NEW problems:"
    printf '%s\n' "$new" | sed 's/^/       /' | tee -a "$LOG"
    VERIFY_FAIL=1
  elif [ "$old" -gt 0 ]; then
    ui_print " - e2fsck $(basename "$1") : ok, nothing new ($old line(s) already in the input)"
  else
    ui_print " - e2fsck $(basename "$1") : clean"
  fi
}

# expect <label> <actual> <expected>
expect() {
  if [ "$2" = "$3" ]; then
    ui_print " - $1 : ok"
  else
    ui_print " - $1 : MISMATCH (got '$2', expected '$3')"
    VERIFY_FAIL=1
  fi
}

verify_outputs() {
  ui_print "-- Verifying the images --"

  fsck_image "$OUT/vendor.img"
  fsck_image "$OUT/system.img"
  fsck_image "$OUT/product.img"
  [ "$OP_DONE" -eq 1 ] && fsck_image "$OUT/OP.img"

  # read back through debugfs, independent of the mounts that wrote them
  img_cat "$OUT/vendor.img" /build.prop >"$TMP/v.bp"
  expect "vendor privapp  " "$(prop_get "$TMP/v.bp" ro.control_privapp_permissions)" "disable"
  expect "vendor apex     " "$(prop_get "$TMP/v.bp" ro.apex.updatable)" "true"
  fst=$(img_first "$OUT/vendor.img" "/etc/fstab.$BOARD")
  expect "vendor fstab    " "$(img_cat "$OUT/vendor.img" "$fst" | grep '^/dev/block/bootdevice/by-name/userdata')" "$FSTAB_LINE"

  img_cat "$OUT/system.img" "$SYS_BP" >"$TMP/s.bp"
  expect "system model    " "$(prop_get "$TMP/s.bp" ro.product.system.model)" "$(prop_get "$STOCK/system.prop" ro.product.system.model)"
  expect "system finger.  " "$(prop_get "$TMP/s.bp" ro.system.build.fingerprint)" "$(prop_get "$STOCK/system.prop" ro.system.build.fingerprint)"
  img_cat "$OUT/product.img" /etc/build.prop >"$TMP/p.bp"
  expect "product model   " "$(prop_get "$TMP/p.bp" ro.product.product.model)" "$(prop_get "$STOCK/product.prop" ro.product.product.model)"
  if port_has "$OVERLAY_ENTRY"; then
    expect "display overlay " "$(img_cat "$OUT/product.img" /overlay/framework-res__auto_generated_rro_product.apk | md5sum | cut -c1-32)" \
      "$(port_cat "$OVERLAY_ENTRY" | md5sum | cut -c1-32)"
  fi
  if [ "$OP_DONE" -eq 1 ]; then
    img_cat "$OUT/OP.img" /cust.prop >"$TMP/c.prop"
    expect "OP VoLTE        " "$(prop_get "$TMP/c.prop" persist.product.lge.supportvolte)" "1"
  fi

  ui_print " "
  [ "$VERIFY_FAIL" -eq 0 ] || abort "Verification failed - see the lines marked above. Do not flash these images."
}

write_flash_notes() {
  s=$SLOT
  ops=""
  [ "$OP_DONE" -eq 1 ] && ops=OP
  {
    echo "Android 13 port for the $DEVICE ($BOARD), model $STOCK_MODEL"
    echo "Built $(date '+%Y-%m-%d %H:%M') by $SELF"
    echo
    echo "Encryption : $ENC_MODE"
    echo "Sound fx   : $AFX_NAME"
    echo "Slot       : $s ($SLOT_FROM)"
    echo
    echo "Flash every image to the _$s partitions - the slot these stock dumps came from."
    echo "Leave boot, dtbo and everything else as they are; the TWRP zip does not touch them either."
    echo
    echo "edl-ng (EDL / Firehose):"
    for p in vbmeta vendor system product $ops; do
      printf '  edl-ng --loader <firehose.elf> write-part %-10s %s.img\n' "${p}_$s" "$p"
    done
    echo
    echo "bkerler edl:"
    for p in vbmeta vendor system product $ops; do
      printf '  edl w %-10s %s.img\n' "${p}_$s" "$p"
    done
    echo
    echo "fastboot (bootloader unlocked, fastboot available):"
    for p in vbmeta vendor system product $ops; do
      printf '  fastboot flash %-10s %s.img\n' "${p}_$s" "$p"
    done
    echo
    echo "Then boot to TWRP:"
    echo "  - Format Data when coming from stock A12 (stock uses forceencrypt) or"
    echo "    when switching between FBE and unencrypted, or /data will not mount"
    echo "  - Otherwise wipe Dalvik / ART Cache and delete /data/resource-cache"
    echo "  - Reboot"
  } >"$OUT/FLASH.txt"
}

#=========================================================================
# main
#
# Everything runs from inside main(), and the call and the exit sit on one
# line, so bash has read the whole script before any of it runs. Editing
# the file mid-run can then no longer derail a build.
#=========================================================================

main() {
  parse_args "$@"

  ui_print "====================================================="
  ui_print "=      LG V50S / G8X ThinQ - Android 13 Port        ="
  ui_print "=            offline image builder                  ="
  ui_print "====================================================="
  ui_print "= Android version : 13                              ="
  ui_print "= Board           : mh2lm                           ="
  ui_print "= Vendor          : stock, patched in place         ="
  ui_print "= Device identity : kept from your stock ROM        ="
  ui_print "= Maintainer      : sidex15                         ="
  ui_print "====================================================="
  ui_print " "

  setup_env
  resolve_inputs

  LOG=$OUT/port.log
  : >"$LOG"
  {
    echo "$SELF - $(date)"
    echo "port    : $PORT"
    echo "system  : $IMG_SYSTEM"
    echo "product : $IMG_PRODUCT"
    echo "vendor  : $IMG_VENDOR"
    echo "OP      : ${IMG_OP:-none}"
    echo "slot    : $SLOT ($SLOT_FROM)"
    echo
  } >>"$LOG"

  choose_encryption
  choose_audio_effect

  OUT_STARTED=1
  remove_outputs

  save_stock_props
  patch_vendor
  flash_images
  restore_stock_props
  patch_display_overlay

  if [ "$skip_volte" -eq 0 ]; then
    patch_op
  else
    ui_print "-- Skipping VoLTE / VoWiFi patch --"
    ui_print " - This device is not V50s ($VOLTE_MODEL), so the OP patch is skipped."
    ui_print " "
  fi

  verify_outputs
  write_flash_notes

  cleanup
  OUT_STARTED=0

  ui_print "====================================================="
  ui_print "=                 Images are ready                  ="
  ui_print "====================================================="
  ui_print "= Output     : $OUT"
  ui_print "= Model      : $STOCK_MODEL"
  ui_print "= Slot       : $SLOT - flash each image to its _$SLOT partition"
  ui_print "= Encryption : $ENC_MODE"
  ui_print "= Sound fx   : $AFX_NAME"
  if [ "$OP_DONE" -eq 1 ]; then
    ui_print "= OP         : VoLTE / VoWiFi patched"
  else
    ui_print "= OP         : not patched, do not flash OP"
  fi
  ui_print "= Took       : $((SECONDS / 60))m $((SECONDS % 60))s"
  ui_print "= Next       : FLASH.txt has the flash commands     ="
  ui_print "= Reminder   : format /data when coming from stock  ="
  ui_print "=              or switching FBE and unencrypted     ="
  ui_print "====================================================="
  ui_print " "
}

main "$@"; exit $?
