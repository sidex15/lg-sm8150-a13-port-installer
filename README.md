# Android 13 Port — offline image builder

Build the LG V50 / V50S / G8X Android 13 port on a PC instead of in TWRP.

You give a script the port (the flashable zip, or its unpacked folder) and a
dump of your phone's **stock A12** partitions. It writes flash-ready images
that are patched the same way the TWRP installer patches the phone:

| Image | What it is |
| --- | --- |
| `vendor.img` | your stock vendor, patched in place (build.prop, fstab, immvibed, sound effect) |
| `system.img` | the A13 system, with your stock device identity restored |
| `product.img` | the A13 product, with your stock device identity restored (V50S/G8X: plus the mh2lm display overlay) |
| `OP.img` | your stock OP, with the VoLTE / VoWiFi patch |
| `vbmeta.img` | the port's vbmeta |

You then flash these with EDL or fastboot. Your stock dumps are only read and
never modified. Every write goes to copies in the output folder, so a failed
or interrupted build costs nothing.

## Which script

The V50 and the V50S/G8X are different boards with different fixes, so each
has its own script. Each script refuses dumps from the other board.

| Phone | Board | Script | Port to use |
| --- | --- | --- | --- |
| LG V50 ThinQ 5G (LM-V500N, …) | `flashlmdd` | `port-v50.sh` | `V50-A13-Port-KR-V500N40d` (zip or folder) |
| LG V50S ThinQ (LM-V510N) / G8X ThinQ (LM-G850…) | `mh2lm` | `port-v50s-g8x.sh` | `V50s-A13-Port` (zip or folder) |

How the two differ, taken from each port's `update-binary`:

| | `port-v50.sh` | `port-v50s-g8x.sh` |
| --- | --- | --- |
| Display overlay in product | — | mh2lm cutout 156x76, status bar 76px, corners 120px |
| OP VoLTE / VoWiFi patch | always | only when the stock model is LM-V510N |
| `volte.sh` | the V50 port's (adds LG Wi-Fi props) | the V50s port's |
| DTS swap | only if the stock eagle libraries have the expected md5, else falls back to AI Sound | always |
| After flashing | wipe Dalvik / ART cache | wipe Dalvik / ART cache and `/data/resource-cache` |

## Requirements
### **A13 port Installer Zips**
**For LG V50s/G8x**

https://drive.google.com/file/d/1aZxKbggvoO53nwqewA0POgjhyHFwB4yz/view?usp=drive_link

**For LG V50**

https://drive.google.com/file/d/1LPlNvUJRbX4Oslvg1Z2vKF3IWFcsDhwu/view?usp=drive_link

**A Linux environment with root.** The images are loop-mounted, which needs root.

- **Windows:** WSL2 (tested with Ubuntu 24.04). Run the script as root with
  `wsl -u root`. No password is needed.
- **Linux:** Debian or Ubuntu, run with `sudo`. Don't use a host with SELinux
  enabled (Fedora, RHEL). It would relabel every file written into the images,
  so the script refuses to run there.

**Packages:**

```sh
sudo apt install e2fsprogs python3 unzip busybox-static
```

`busybox` must be the **static** build: the port's `volte.sh` runs under it
inside a chroot. The script checks this and explains if it isn't.

**Disk space:** about 10 GB free at the output folder. The WSL virtual disk
itself needs almost nothing, because the images stream straight to `--out`.
Under WSL, put `--out` on a Windows drive if your WSL disk is small.

**Stock dumps of the active slot:** `system`, `product`, `vendor` and `OP`, as
raw partition dumps (EDL gives you exactly that). A full EDL backup already
has them, named like `system_a.bin` and `OP_a.bin`, together with the
`gpt_main*.bin` files the script reads the active slot from.

Only one slot of a dump is usually valid. On the tested V50 backup, slot `b`
had no filesystem at all. Use the slot the phone boots from; the script picks
it from the GPT dump automatically.

## Step 1 — dump the stock partitions

Skip this if you already have a full EDL backup of the phone on stock A12.

With edl-ng, for slot `a`:

```sh
edl-ng --loader "LGE SM8150 Firehose.elf" read-part system_a  system_a.bin
edl-ng --loader "LGE SM8150 Firehose.elf" read-part product_a product_a.bin
edl-ng --loader "LGE SM8150 Firehose.elf" read-part vendor_a  vendor_a.bin
edl-ng --loader "LGE SM8150 Firehose.elf" read-part OP_a      OP_a.bin
```

Put them in one folder. Without the `gpt_main*.bin` files the script can't see
which slot is active. It then assumes `a` and says so; pass `--slot b` if your
phone runs on slot `b` (bkerler's `edl getactiveslot` tells you which).

**Dump the phone while it is still on stock A12.** The script reads your device
identity (model, fingerprint, build id and date) out of these dumps and writes
it into the A13 images, exactly as the TWRP installer does before it flashes.

## Step 2 — build the images

**Windows (PowerShell, WSL):**

```powershell
wsl -u root --exec bash /mnt/f/lg-sm8150-a13-port-installer/port-v50s-g8x.sh `
    --port  'F:\edl\V50-A13-Port\V50s-A13-Port\V50s-G8x-A13-Port.zip' `
    --stock 'F:\edl\dumps\universal' `
    --out   'F:\edl\a13-v50s'
```

Keep the `--exec`. It hands the Windows paths to the script untouched; without
it, WSL passes the line through a shell that eats the backslashes. The script
converts `F:\…` paths to `/mnt/f/…` itself. Forward slashes (`F:/edl/…`) work
too.

**Linux:**

```sh
sudo ./port-v50.sh --port V50-A13-Port-KR-V500N40d.zip --stock ~/v50_backup --out ~/a13-v50
```

The script asks the same two questions as the TWRP installer, unless you answer
them with options:

- **/data encryption:** File-Based Encryption (default) or unencrypted
- **Global sound effect:** DTS:X on every app (default) or LG 3D Sound Engine

A build takes about 4 minutes on WSL with everything on one NTFS drive. Most of
that is copying about 9 GB of images. The output folder ends up with:

```
vendor.img  system.img  product.img  OP.img  vbmeta.img
FLASH.txt       flash commands for your slot (edl-ng, bkerler edl, fastboot)
port.log        everything the build did, including volte.sh's own output
stock-props/    the device props saved from your stock system / system_ext / product
```

`OP.img` is only written when the OP was patched. For a V50S/G8X that isn't an
LM-V510N the OP stays stock, so don't flash one.

## Step 3 — flash

`FLASH.txt` lists the exact commands. Flash every image to the partitions of
the slot the dumps came from, for example with edl-ng:

```sh
edl-ng --loader "LGE SM8150 Firehose.elf" write-part vbmeta_a  vbmeta.img
edl-ng --loader "LGE SM8150 Firehose.elf" write-part vendor_a  vendor.img
edl-ng --loader "LGE SM8150 Firehose.elf" write-part system_a  system.img
edl-ng --loader "LGE SM8150 Firehose.elf" write-part product_a product.img
edl-ng --loader "LGE SM8150 Firehose.elf" write-part OP_a      OP.img
```

Leave `boot`, `dtbo` and everything else alone; the TWRP zip doesn't touch them
either. Then boot to TWRP:

- **Format Data** if you are coming from stock A12, or switching between FBE
  and unencrypted. Stock uses `forceencrypt`, so `/data` won't mount otherwise.
  This erases internal storage.
- Otherwise wipe **Dalvik / ART cache** (V50S/G8X: also delete
  `/data/resource-cache`).
- Reboot.

## Options

| Option | Meaning |
| --- | --- |
| `--port PATH` | the port: flashable zip or unpacked folder (same entry names either way) |
| `--stock DIR` | folder with the stock dumps (`<part>_<slot>.bin`, `.img`, or without the slot suffix) |
| `--slot a\|b` | slot to read and flash. Default: the active slot in `gpt_main*.bin`, else `a` |
| `--system/--product/--vendor/--op FILE` | take one stock image from somewhere else |
| `--out DIR` | output folder. Default: `./out-v50` or `./out-v50s-g8x` |
| `--encryption fbe\|none` | skip the encryption question |
| `--soundfx dts\|ais` | skip the sound effect question |
| `--force` | write into a folder that already has images from an earlier build |

With no terminal attached (for example, when called from another script), the
questions default to FBE and DTS:X, like the installer does with no key input.
Set `BUSYBOX=/path/to/busybox` to use a static busybox that isn't on `PATH`.

## What gets patched

The stages run in the same order as the TWRP installer:

1. **Stock device identity is saved** from the stock `system/build.prop`,
   `system/system_ext/etc/build.prop` and `product/etc/build.prop`:
   `ro.product.*.{brand,device,manufacturer,model,name}` and
   `ro.*.build.{date,date.utc,fingerprint,id}`. `ro.build.version.*` isn't
   touched. The board is checked here: V50 dumps stop the V50S script and the
   other way round.
2. **Stock vendor is patched in place.**
   - `build.prop`: `ro.control_privapp_permissions=disable`, `ro.apex.updatable=true`
   - every `etc/fstab.*` with a userdata line: the FBE or unencrypted userdata line.
     On the V50S that includes `fstab.factory`.
   - `bin/immvibed`: the vibration fix
   - sound effect: the patched DTS Eagle libraries, or LG AI Sound registered in
     `audio_effects.xml`, plus `ro.vendor.lge.feature.global_effect_{ais,dts}=true`
   - `.a12bak` stock backups next to every file changed, as the installer leaves them
3. **The A13 `vbmeta.img`, `system.img` and `product.img` are written.** Each
   must fit its partition; the dump's size is the partition size. Using the
   wrong port for the phone stops here.
4. **The saved identity is merged** into the A13 build.prop files.
5. **V50S/G8X only:** the mh2lm display overlay replaces
   `product/overlay/framework-res__auto_generated_rro_product.apk`.
6. **OP:** the port's `volte.sh` runs, then the port's `OP/config` files are copied in.

## How it stays identical to the TWRP install

- **Files are written in place** (`cat > existing_file`), never replaced, so
  every existing file keeps its inode, mode, owner and SELinux label. That's the
  same technique as `update-binary`.
- **New files get SELinux labels.** The PC kernel has no SELinux, so files
  created on a loop mount come out unlabelled, where TWRP's kernel would have
  given them their folder's context. The script gives each new file its folder's
  label (`.a12bak` backups, AI Sound files, OP backups). Files the installer
  `chcon`s explicitly get the same explicit contexts.
- **`volte.sh` runs unmodified,** in a chroot where `/OP` is the mounted OP
  image and the tools are busybox, just like TWRP.

**One deliberate difference: `sed` in that chroot is GNU sed.** Every append
line in `volte.sh` uses `sed -i -z`, and busybox `sed` has no `-z` option. That
includes the osm0sis BusyBox 1.30.1 shipped in the zips (checked by running it
under qemu). So when the zip is flashed in TWRP, those lines fail. The props
are deleted by the line before, but never added back; only the `/c` region and
operator replacements take effect. The images from this script have the VoLTE
/ VoWiFi props `volte.sh` means to add.

## Verification

Before it declares the images ready, the script checks them and stops if
anything is off. When it stops, it deletes the unfinished images, so nothing
half-built is left to flash.

- **e2fsck:** each image is checked read-only (`e2fsck -fn`) right after it's
  copied and again at the end. Any finding that wasn't in the input fails the
  build. The port's system and product images already carry one harmless
  `Padding at end of inode bitmap is not set` from how they were built; that
  shows as "nothing new".
- **Read-back:** the images are read back through debugfs, independently of the
  mounts that wrote them. Checked: the vendor props and fstab line, the restored
  model and fingerprint, the display overlay's md5 (V50S), and the VoLTE prop in
  `OP/cust.prop`.

Tested on 2026-09-29 under WSL2 Ubuntu 24.04, against stock A12 dumps of an
LM-V500N (flashlmdd) and an LM-V510N (mh2lm):

| Build | Result |
| --- | --- |
| V50S, release zip, DTS, FBE | passed |
| V50, port folder, AI Sound, unencrypted | passed |
| V50, release zip, DTS (md5 gate), FBE | passed, 3m 43s |

For each build, every file in the input images was diffed against the output.
Only the files listed under "What gets patched" differed; the other ~13,000
entries were byte-identical, with the same mode, owner and SELinux label. That
test didn't cover a G8X, because there was no G8X dump to test with.

## Troubleshooting

| Message | Cause |
| --- | --- |
| `Run as root` | use `wsl -u root …` or `sudo` |
| `These dumps are from a flashlmdd (LG V50)` / `… mh2lm …` | wrong script for this phone |
| `… has no ext4 superblock … (an empty slot?)` | that slot isn't in use: try the other `--slot` |
| `… is an Android sparse image` | convert first: `simg2img in.img out.img` |
| `The port's system.img … is bigger than this phone's partition` | wrong port for this phone |
| `… will not run in a chroot - it must be a static build` | `apt install busybox-static`, or `BUSYBOX=/path/to/static/busybox` |
| `This host runs SELinux` | use WSL2 or a Debian/Ubuntu machine |
| `$'\r': command not found` | the script got CRLF line endings; convert it back to LF |
| `Verification failed` | see the marked lines and `port.log`; don't flash that folder |

## Keeping in sync with the installers

The scripts read everything that ships in the port straight from the zip or
folder: `volte.sh`, `OP/config`, `vendor/bin/immvibed`, `audiofx/`, the display
overlay and the images. Update those in the port and the next build picks them
up.

What's coded into the scripts is the logic of each `update-binary`: the prop
lists, the fstab lines, the DTS md5 constants (V50) and the stage order. When
an `update-binary` changes, make the same change in its script. The functions
keep the installer's names and structure so the two can be compared side by
side.

## Todo
* Make a universal Port installer for the rest of the LG SM8150 Devices (G8 and G8s)

## Contributions
Any contributions is good to help this A13 port for usable for all LG sm8150 Devices. :)