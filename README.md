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
4. Plug in all drives to be tested
5. Run ./test.sh
6. Review logs on each drive when complete
```

---

## License

MIT — free to use, modify, and distribute.
