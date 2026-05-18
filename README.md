# Automated Fake Capacity Detector & Drive Fault Tester

> **Designed for [Parted Magic](https://partedmagic.com/)** — A comprehensive suite of scripts for detecting counterfeit storage devices, verifying true capacity, and confirming drives are in full working order before deployment or resale.

---

## Overview

Counterfeit flash storage is rampant. USB sticks, SD cards, and even SSDs are routinely sold with falsified firmware that reports a capacity far greater than what actually exists — until the data corruption begins. This toolkit automates the full process of detecting fake capacity, stress-testing every sector, and producing an auditable evidence trail, all in parallel across multiple drives simultaneously.

Built around the industry-standard **F3** (Fight Flash Fraud) toolset and tightly integrated with Parted Magic's secure erase capabilities, these scripts turn a tedious manual process into a fast, hands-off workflow that produces documented results you can trust.

---

## Supported Drive Types

| Category | Types |
|---|---|
| **Mechanical Drives** | SATA HDD, USB HDD |
| **Solid State Drives** | SATA SSD, USB SSD, PCIe NVMe |
| **Flash Drives** | USB-A, USB-C |
| **Memory Cards** | SD, MicroSD |

---

## Scripts

| Script | Purpose |
|---|---|
| `test.sh` | Main test script — runs the full detection and verification workflow across all connected drives in parallel |
| `unplug.sh` | Safely unplugs SATA (hot-plug enabled) and USB devices without a full system shutdown |
| `vnc.sh` | Enables remote desktop access so you can monitor and control the process from a Windows PC or any other platform |

---

## How It Works

### Pre-Use: Secure Erase First

Before running `test.sh`, all drives should be put through **Parted Magic's Erase tool**. This performs a Cryptographic Erase at the hardware level — compliant with major data protection standards — using the drive's own controller to carry out the wipe. This step alone is a powerful diagnostic: it can surface SMART alerts, trigger bad sector relocation, and reveal underlying NAND or platter issues that a software wipe would miss.

| Drive Type | Erase Method |
|---|---|
| SATA HDD / SSD | ATA Secure Erase or ATA Sanitize |
| NVMe SSD | NVMe Secure Erase |
| USB Flash Drives / SD / MicroSD | `dd` block zero fill *(Cryptographic Erase not supported)* |

> **Recommended verification depth:**
> - Drives **above 64 GB** — set Parted Magic erase verification to **10%**
> - Drives **64 GB or below** — set Parted Magic erase verification to **20%**

When the erase completes, Parted Magic automatically saves a report to `/home/partedmagic/`. The test workflow will pick these up and copy them directly onto the drive as evidence of the secure erase — no manual file management needed.

---

### The Test Workflow (`test.sh`)

`test.sh` processes every eligible drive **simultaneously** in the background. Each drive goes through the following automated pipeline:

```
1.  Wipe the existing partition table
2.  Create a fresh msdos partition table with a single partition
3.  Format as exFAT
4.  Mount the drive and run F3Write + F3Read — logging all results
5.  Recreate the partition table and single partition
6.  Reformat as exFAT, labelled with the last 4 characters of the drive's serial number
7.  Mount the finalised drive
8.  Create a test_reports_XXXX folder on the drive (XXXX = last 4 of serial)
9.  Match and move the Parted Magic Eraser logs into that folder (matched by serial number inside the file)
10. Move F3 test logs onto the drive (matched by serial number, not device path)
```

#### Why F3Write + F3Read?

**F3Write** fills every available byte of the drive with a deterministic pseudo-random pattern. **F3Read** then verifies that every single byte reads back correctly. Together they confirm the drive's true usable capacity — no firmware tricks, no phantom sectors. Because the write covers the entire surface, it also acts as a thorough wipe, making it practically impossible to recover any previous data from the device.

---

## Selecting Drives — `drives.conf`

Before running the script you need to tell it which drives to process. Open `drives.conf` and edit the `DRIVES` line:

```
DRIVES=(sda, sdb, sdc)
```

Add or remove drive names separated by commas — no quotes needed. When `test.sh` starts it will display the list and ask you to confirm before touching anything.

### Finding the right drive names

The best way to identify which drives you want to test is to open **Disk Health (GSmartControl)** from the Parted Magic desktop. It lists every connected drive along with its device name (e.g. `sda`, `sdb`), model, serial number, and SMART health status — giving you everything you need to pick the right devices and spot any that are already showing faults before the test even begins.

> **Important:** double-check that your Parted Magic boot drive is **not** included in `drives.conf`. `test.sh` will wipe and reformat every drive it is given without further warning beyond the initial confirmation prompt.

---

## Getting Started

### Requirements

- [Parted Magic](https://partedmagic.com/) (live boot environment)
- `f3write` and `f3read` (included in Parted Magic)
- `exfatprogs` or `exfat-utils` for exFAT formatting (included in Parted Magic)

### Setup

Before you can run any `.sh` file on Linux you need to mark it as executable. Open a terminal and run:

```bash
chmod +x test.sh unplug.sh vnc.sh
```

That's it. No installation, no dependencies to chase down.

---

## Running the Scripts

### Run the main test

```bash
./test.sh
```

Plug in all the drives you want to test **before** running the script. The script will detect all eligible block devices, exclude your system drive, and begin processing them all in parallel. Results are logged and written directly to each drive on completion.

---

### Unplug a drive safely

```bash
./unplug.sh
```

Use this to safely eject SATA hot-plug or USB devices mid-session without rebooting Parted Magic.

---

### Enable remote desktop (VNC)

```bash
./vnc.sh
```

This starts a VNC server with the password set to `fakechecker`. To find the IP address of your Parted Magic machine, run:

```bash
ifconfig
```

Alternatively, check your router's connected device list. You can then connect from Windows using any VNC viewer (e.g. RealVNC, TightVNC, TigerVNC) by entering `<IP address>:5900`.

---

## How Long Does It Take?

This is the gold standard in drive testing — and that thoroughness comes at a cost: time. Every byte of every drive is written, then independently verified. There are no shortcuts, and there shouldn't be. The process exists to catch drives that cheat, and a rushed test is exactly what counterfeit firmware is designed to survive.

**How long will vary significantly depending on:**

- Drive capacity — a 256 GB drive takes considerably longer than a 32 GB one
- Drive speed — a fast NVMe will finish far sooner than a slow USB 2.0 flash drive
- Bus speed — USB 2.0, USB 3.0, SATA, and PCIe all have very different real-world throughputs
- System load — running multiple drives in parallel shares the host's I/O bandwidth
- Drive health — a drive with thermal throttling or marginal sectors will slow down under sustained load

There is no progress bar. The script will run each tool sequentially per drive, silently in the background, and when everything is complete it will print a summary of every drive — what passed, what failed, and why.

**For large or slow drives, plan to run this overnight.** If you are processing drives in bulk, make sure your setup has adequate airflow and cooling. Hard drives — particularly SSDs — will throttle their speeds when they overheat, which not only extends the test time but can mask marginal hardware that would otherwise fail. A drive that throttles and limps through is not a drive you want to trust.

### Monitoring Progress

Although there is no built-in progress meter, you can check in on what each drive is doing at any time by opening a second terminal and running:

```bash
iostat -m 3 -p
```

This refreshes every 3 seconds and shows live read/write activity per device. Here is how to interpret what you see:

| Activity | What it means |
|---|---|
| **High writes, low reads** | Drive is in the F3Write phase — laying down the pseudo-random pattern across the full capacity. For flash drives and SD cards that skipped the cryptographic erase, this is also effectively a deep wipe of any residual data. This is the early stage. |
| **High reads, low writes** | Drive is in the F3Read phase — verifying every byte written matches what was recorded. This is the final and most critical stage. It still takes a long time, but completion is approaching. Any byte that does not match is logged as a failure. |
| **Low or no activity** | The drive has finished, or is between steps (formatting, partitioning, copying logs). |

If a drive fails F3Read, the cause is almost always one of two things: **fake capacity** — extremely common with USB flash drives, SD cards, and budget Chinese SSDs — or genuine read/write faults on a drive that is failing. Either way, the result file on the drive will tell you exactly what was lost and where.

---

## Output & Evidence

At the end of each drive's workflow, the drive itself contains a complete evidence package inside `test_reports_XXXX/`:

- Parted Magic Eraser report (matched to this drive's serial number)
- F3Write log (capacity test — write pass)
- F3Read log (capacity test — read verification pass)

This makes each tested drive self-documenting — the audit trail travels with the hardware.

---

## Recommended Workflow

```
1. Boot Parted Magic from USB
2. Run the Parted Magic Erase tool on all drives
   └── HDD/SSD: ATA Secure Erase / ATA Sanitize / NVMe Secure Erase
   └── Flash/SD: dd zero fill
3. chmod +x test.sh unplug.sh vnc.sh
4. Open Disk Health (GSmartControl) to identify drive names (sda, sdb, etc.)
5. Edit drives.conf with the drives you want to test
6. Run ./test.sh — confirm the drive list when prompted
7. Review logs on each drive when complete
```

---

## License

MIT — free to use, modify, and distribute.
