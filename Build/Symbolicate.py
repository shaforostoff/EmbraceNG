#!/usr/bin/env python3
"""
Symbolicate an on-disk EscapePod crash report.

EscapePod (Source/EscapePod.m) writes its reports from an async-signal-safe
handler, so everything in them is raw lowercase hex with no symbol names: a
frame-pointer backtrace per thread, the crashing thread's registers, siginfo,
and a binary image list.  Symbolication was meant to happen on the telemetry
server, which leaves the copies under

    ~/Library/Application Support/EmbraceNG/Crashes/

unreadable.  This script does that job locally, using atos plus the binaries
and dSYMs it can find on this machine.

    Build/Symbolicate.py                    # newest report
    Build/Symbolicate.py --all              # every report, oldest first
    Build/Symbolicate.py <path> [<path>...]
    Build/Symbolicate.py --search Build/Debug   # extra place to look for binaries/dSYMs

Frames from the dyld shared cache (every system framework) cannot be
symbolicated from a file, because those images do not exist on disk; they are
printed as "image + offset", which is also what an unsymbolicated .ips shows.
Frames from EmbraceNG itself symbolicate fully when a matching binary or dSYM
is found -- pass --search pointing at the build or archive that produced the
crash if it is not somewhere obvious.

Addresses past frame 0 are return addresses, printed raw, the way Apple's
crash reports print them.  A return address sits just after its call, so a
frame whose call is the very last instruction of a function can attribute to
the following symbol.
"""

import argparse
import os
import re
import shutil
import subprocess
import sys
import time

CPU_TYPE_X86 = 7
CPU_TYPE_X86_64 = 0x01000007
CPU_TYPE_ARM = 12
CPU_TYPE_ARM64 = 0x0100000C

CPU_SUBTYPE_MASK = 0x00FFFFFF
CPU_SUBTYPE_X86_64_H = 8
CPU_SUBTYPE_ARM64E = 2

# sizeof(uap->uc_mcontext->__ss) / sizeof(void *), which is what EscapePod
# walks when it writes its REGI lines.
ARM64_REGISTERS = (
    ["x%d" % i for i in range(29)] + ["fp", "lr", "sp", "pc", "cpsr"]
)
X86_64_REGISTERS = [
    "rax", "rbx", "rcx", "rdx", "rdi", "rsi", "rbp", "rsp",
    "r8", "r9", "r10", "r11", "r12", "r13", "r14", "r15",
    "rip", "rflags", "cs", "fs", "gs",
]

SIGNAL_NAMES = {
    1: "SIGHUP", 2: "SIGINT", 3: "SIGQUIT", 4: "SIGILL", 5: "SIGTRAP",
    6: "SIGABRT", 7: "SIGEMT", 8: "SIGFPE", 9: "SIGKILL", 10: "SIGBUS",
    11: "SIGSEGV", 12: "SIGSYS", 13: "SIGPIPE",
}

# si_code 0 is SI_USER regardless of signal: something called kill() or
# raise() (abort() included), so si_addr is not a fault address.
SI_USER = 0

# Other si_code values are interpreted relative to si_signo.
SIGNAL_CODES = {
    "SIGILL": {1: "ILL_ILLOPC", 2: "ILL_ILLTRP", 3: "ILL_PRVOPC",
               4: "ILL_ILLOPN", 5: "ILL_ILLADR", 6: "ILL_PRVREG",
               7: "ILL_COPROC", 8: "ILL_BADSTK"},
    "SIGFPE": {1: "FPE_FLTDIV", 2: "FPE_FLTOVF", 3: "FPE_FLTUND",
               4: "FPE_FLTRES", 5: "FPE_FLTINV", 6: "FPE_FLTSUB",
               7: "FPE_INTDIV", 8: "FPE_INTOVF"},
    "SIGSEGV": {1: "SEGV_MAPERR", 2: "SEGV_ACCERR"},
    "SIGBUS": {1: "BUS_ADRALN", 2: "BUS_ADRERR", 3: "BUS_OBJERR"},
    "SIGTRAP": {1: "TRAP_BRKPT", 2: "TRAP_TRACE"},
}


def arch_for_cpu(cputype, cpusubtype):
    subtype = cpusubtype & CPU_SUBTYPE_MASK

    if cputype == CPU_TYPE_ARM64:
        return "arm64e" if subtype == CPU_SUBTYPE_ARM64E else "arm64"
    if cputype == CPU_TYPE_X86_64:
        return "x86_64h" if subtype == CPU_SUBTYPE_X86_64_H else "x86_64"
    if cputype == CPU_TYPE_ARM:
        return "arm"
    if cputype == CPU_TYPE_X86:
        return "i386"

    return "unknown"


class Image(object):
    def __init__(self, addr, size, vmaddr, version, cputype, cpusubtype, uuid, path):
        self.addr = addr
        self.size = size
        self.vmaddr = vmaddr
        self.version = version
        self.cputype = cputype
        self.cpusubtype = cpusubtype
        self.uuid = uuid
        self.path = path

        # Resolved lazily by Symbolizer, cached here.
        self.binary = None
        self.did_look_for_binary = False

    @property
    def name(self):
        return os.path.basename(self.path) or self.path

    @property
    def arch(self):
        return arch_for_cpu(self.cputype, self.cpusubtype)

    @property
    def end(self):
        return self.addr + self.size

    def contains(self, address):
        return self.addr <= address < self.end

    @property
    def pretty_uuid(self):
        u = self.uuid
        if len(u) != 32:
            return u
        return "%s-%s-%s-%s-%s" % (u[0:8], u[8:12], u[12:16], u[16:20], u[20:32])


class Frame(object):
    def __init__(self, address, kind):
        self.address = address
        self.kind = kind          # "pc", "lr" or "ret"
        self.image = None
        self.symbol = None
        self.note = None


class Thread(object):
    def __init__(self, crashed):
        self.crashed = crashed
        self.frames = []
        self.note = None


class Report(object):
    def __init__(self, path):
        self.path = path
        self.header = {}
        self.threads = []
        self.exception_name = None
        self.exception_frames = []
        self.exception_lines = []
        self.timestamp = None
        self.signo = None
        self.sicode = None
        self.siaddr = None
        self.custom = {}
        self.registers = []
        self.images = []
        self.warnings = []
        self.unknown_lines = 0

    def image_for(self, address):
        for image in self.images:
            if image.contains(address):
                return image
        return None

    @property
    def has_link_register(self):
        """EscapePod only writes a link register on arm64 (x86_64 returns NULL)."""
        cputypes = [i.cputype for i in self.images]
        if cputypes:
            arm = sum(1 for c in cputypes if c in (CPU_TYPE_ARM64, CPU_TYPE_ARM))
            return arm * 2 > len(cputypes)
        return self.header.get("arch", "").startswith(("arm", "armv"))

    @property
    def register_names(self):
        if len(self.registers) == len(ARM64_REGISTERS):
            return ARM64_REGISTERS
        if len(self.registers) == len(X86_64_REGISTERS):
            return X86_64_REGISTERS
        return ["r%d" % i for i in range(len(self.registers))]

    @property
    def signal_name(self):
        if self.signo is None:
            return None
        return SIGNAL_NAMES.get(self.signo, "signal %d" % self.signo)

    @property
    def signal_code_name(self):
        table = SIGNAL_CODES.get(self.signal_name or "", {})
        return table.get(self.sicode)


def parse_hex(text, default=0):
    try:
        return int(text.strip(), 16)
    except (ValueError, AttributeError):
        return default


def split_pc_and_lr(token, report):
    """
    EscapePod writes the program counter and, on arm64, the link register with
    no separator between them:

        file_writef_safe(file, "%x", pc);
        if (lr) file_writef_safe(file, "%x", lr);

    Both are variable width (its %x suppresses leading zeros), so the boundary
    has to be recovered.  Concatenating two ~36-bit addresses gives a ~72-bit
    number that cannot land inside any loaded image, so requiring both halves
    to resolve is a strong test.  Returns (pc, lr_or_None, note_or_None).
    """
    whole = parse_hex(token)

    if not report.has_link_register:
        return whole, None, None

    # A zero program counter -- a call through a null function pointer -- is
    # written as a bare "0", and no nonzero value is ever written with a
    # leading zero.  So a token that starts with "0" and keeps going splits
    # exactly here, with no guessing.
    if token == "0":
        return 0, None, None
    if token.startswith("0"):
        return 0, parse_hex(token[1:]), None

    candidates = []

    for i in range(1, len(token)):
        left, right = token[:i], token[i:]

        # A value written by %x never carries a leading zero unless it is
        # exactly "0", and a zero link register is not written at all.
        if len(left) > 1 and left.startswith("0"):
            continue
        if right.startswith("0"):
            continue

        pc, lr = parse_hex(left), parse_hex(right)

        if report.image_for(pc) and report.image_for(lr):
            candidates.append((abs(len(left) - len(right)), pc, lr))

    if candidates:
        candidates.sort()
        _, pc, lr = candidates[0]
        note = None
        if len(candidates) > 1:
            note = "pc/lr split ambiguous, %d readings fit" % len(candidates)
        return pc, lr, note

    if report.image_for(whole):
        # No split works, but the token on its own is a real code address:
        # the link register was zero and therefore never written.
        return whole, None, None

    return whole, None, "pc not inside any known image; pc/lr may be run together"


def parse_report(path):
    report = Report(path)

    with open(path, "rb") as f:
        data = f.read()

    text = data.decode("utf-8", errors="replace")
    truncated_tail = bool(text) and not text.endswith("\n")
    lines = text.split("\n")

    pending_threads = []

    for line in lines:
        if not line:
            continue

        if len(line) < 6 or line[4] != ":":
            report.unknown_lines += 1
            continue

        tag, payload = line[:4], line[6:] if line[5:6] == " " else line[5:]

        if tag in ("arch", "uidn", "name", "bund", "vers", "soft"):
            report.header[tag] = payload

        elif tag in ("THRC", "THRD"):
            pending_threads.append((tag == "THRC", payload))

        elif tag == "excn":
            report.exception_name = payload
        elif tag == "excs":
            report.exception_frames = [parse_hex(t) for t in payload.split(",") if t.strip()]
        elif tag == "excl":
            report.exception_lines.append(payload)

        elif tag == "time":
            report.timestamp = parse_hex(payload)
        elif tag == "sign":
            report.signo = parse_hex(payload)
        elif tag == "sigc":
            report.sicode = parse_hex(payload)
        elif tag == "siga":
            report.siaddr = parse_hex(payload)

        elif re.fullmatch(r"STR[0-3]", tag):
            report.custom[tag] = payload

        elif tag == "REGI":
            report.registers.append(parse_hex(payload))

        elif tag == "BINI":
            fields = payload.split(",", 9)
            if len(fields) != 10:
                report.unknown_lines += 1
                continue

            version = (parse_hex(fields[3]) << 16) | (parse_hex(fields[4]) << 8) | parse_hex(fields[5])

            report.images.append(Image(
                addr=parse_hex(fields[0]),
                size=parse_hex(fields[1]),
                vmaddr=parse_hex(fields[2]),
                version=version,
                cputype=parse_hex(fields[6]),
                cpusubtype=parse_hex(fields[7]),
                # to_hex_string_safe() suppresses leading zero nibbles across
                # the whole 16-byte UUID, so short strings need re-padding.
                uuid=fields[8].strip().rjust(32, "0"),
                path=fields[9],
            ))

        else:
            report.unknown_lines += 1

    # Thread lines are parsed after BINI, because recovering the pc/lr
    # boundary needs the image ranges.
    for crashed, payload in pending_threads:
        thread = Thread(crashed)
        tokens = [t.strip() for t in payload.split(",")]

        if tokens and tokens[0]:
            pc, lr, note = split_pc_and_lr(tokens[0], report)
            thread.frames.append(Frame(pc, "pc"))
            if lr is not None:
                thread.frames.append(Frame(lr, "lr"))
            thread.note = note

        for token in tokens[1:]:
            if token:
                thread.frames.append(Frame(parse_hex(token), "ret"))

        report.threads.append(thread)

    if truncated_tail:
        report.warnings.append(
            "Report does not end in a newline: it was truncated, either by "
            "EscapePod's 256 KB cap or because the process died mid-write. "
            "Binary images are written last, so they are lost first."
        )

    if not report.images:
        report.warnings.append(
            "No binary images in this report; nothing can be symbolicated and "
            "arm64 pc/lr pairs cannot be separated."
        )

    if report.unknown_lines:
        report.warnings.append("%d line(s) could not be parsed." % report.unknown_lines)

    return report


class Symbolizer(object):
    def __init__(self, search_paths=(), verbose=False):
        self.search_paths = list(search_paths)
        self.verbose = verbose
        self.atos = shutil.which("atos")
        self.dwarfdump = shutil.which("dwarfdump")
        self.mdfind = shutil.which("mdfind")
        self.uuid_cache = {}
        self.notes = []

    def _log(self, message):
        if self.verbose:
            sys.stderr.write("Symbolicate: %s\n" % message)

    def _uuids_for_file(self, path):
        if path in self.uuid_cache:
            return self.uuid_cache[path]

        uuids = set()

        if self.dwarfdump:
            try:
                out = subprocess.run(
                    [self.dwarfdump, "--uuid", path],
                    capture_output=True, text=True, timeout=30,
                ).stdout
            except (OSError, subprocess.SubprocessError):
                out = ""

            for match in re.finditer(r"\b([0-9A-Fa-f]{8}(?:-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12})\b", out):
                uuids.add(match.group(1).replace("-", "").lower())

        self.uuid_cache[path] = uuids
        return uuids

    def _candidates_for(self, image):
        """Files that might carry symbols for image, best first."""
        candidates = []

        if self.mdfind:
            query = "com_apple_xcode_dsym_uuids == \"%s\"" % image.pretty_uuid.upper()
            try:
                out = subprocess.run(
                    [self.mdfind, query], capture_output=True, text=True, timeout=30,
                ).stdout
            except (OSError, subprocess.SubprocessError):
                out = ""

            for line in out.splitlines():
                line = line.strip()
                if not line:
                    continue
                dwarf_dir = os.path.join(line, "Contents", "Resources", "DWARF")
                if os.path.isdir(dwarf_dir):
                    for entry in sorted(os.listdir(dwarf_dir)):
                        candidates.append(os.path.join(dwarf_dir, entry))
                else:
                    candidates.append(line)

        for root in self.search_paths:
            for dirpath, dirnames, filenames in os.walk(root):
                dirnames[:] = [d for d in dirnames if not d.endswith(".build")]
                if image.name in filenames:
                    candidates.append(os.path.join(dirpath, image.name))
                if (image.name + ".dSYM") in dirnames:
                    dwarf_dir = os.path.join(dirpath, image.name + ".dSYM",
                                             "Contents", "Resources", "DWARF")
                    if os.path.isdir(dwarf_dir):
                        for entry in sorted(os.listdir(dwarf_dir)):
                            candidates.append(os.path.join(dwarf_dir, entry))

        if os.path.isfile(image.path):
            candidates.append(image.path)
            sibling = image.path + ".dSYM"
            dwarf_dir = os.path.join(sibling, "Contents", "Resources", "DWARF")
            if os.path.isdir(dwarf_dir):
                for entry in sorted(os.listdir(dwarf_dir)):
                    candidates.insert(0, os.path.join(dwarf_dir, entry))

        seen = set()
        ordered = []
        for c in candidates:
            if c not in seen:
                seen.add(c)
                ordered.append(c)
        return ordered

    def binary_for(self, image):
        if image.did_look_for_binary:
            return image.binary

        image.did_look_for_binary = True

        mismatches = []

        for candidate in self._candidates_for(image):
            if not os.path.isfile(candidate):
                continue

            uuids = self._uuids_for_file(candidate)

            if image.uuid in uuids:
                self._log("%s -> %s" % (image.name, candidate))
                image.binary = candidate
                return candidate

            if uuids:
                mismatches.append(candidate)

        if mismatches:
            self.notes.append(
                "%s: found %s but its UUID does not match the report "
                "(%s); skipped rather than print wrong symbols."
                % (image.name, mismatches[0], image.pretty_uuid)
            )
        return None

    def symbolicate(self, report):
        by_image = {}

        all_frames = []
        for thread in report.threads:
            all_frames.extend(thread.frames)

        exception_frames = [Frame(a, "ret") for a in report.exception_frames]
        all_frames.extend(exception_frames)

        for frame in all_frames:
            frame.image = report.image_for(frame.address)
            if frame.image is not None:
                by_image.setdefault(id(frame.image), (frame.image, []))[1].append(frame)

        if not self.atos:
            self.notes.append("atos not found; frames left as image + offset.")
            return exception_frames

        for image, frames in by_image.values():
            binary = self.binary_for(image)
            if not binary:
                continue

            addresses = sorted({f.address for f in frames})
            command = [
                self.atos, "-o", binary, "-arch", image.arch,
                "-l", "0x%x" % image.addr,
            ]

            try:
                result = subprocess.run(
                    command,
                    input="\n".join("0x%x" % a for a in addresses) + "\n",
                    capture_output=True, text=True, timeout=120,
                )
            except (OSError, subprocess.SubprocessError) as e:
                self.notes.append("atos failed for %s: %s" % (image.name, e))
                continue

            if result.returncode != 0:
                message = (result.stderr or "").strip().splitlines()
                self.notes.append("atos failed for %s: %s"
                                  % (image.name, message[0] if message else "exit %d" % result.returncode))
                continue

            output = [l.strip() for l in result.stdout.splitlines()]
            resolved = dict(zip(addresses, output))

            for frame in frames:
                symbol = resolved.get(frame.address)
                # atos echoes the address back when it cannot do better.
                if symbol and not symbol.startswith("0x"):
                    frame.symbol = symbol

        return exception_frames


def format_frame(index, frame, crashed=False):
    if frame.image is not None:
        image_name = frame.image.name
        offset = frame.address - frame.image.addr
        detail = frame.symbol or ("%s + %d" % (image_name, offset))
    else:
        image_name = "???"
        detail = "unknown address"

    if frame.kind == "lr":
        tag = "  <- link register"
    elif frame.kind == "pc" and crashed:
        tag = "  <- crashed here"
    else:
        tag = ""

    return "%-4d%-30s 0x%016x  %s%s" % (index, image_name[:30], frame.address, detail, tag)


def render(report, symbolizer, exception_frames, all_images=False):
    out = []
    w = out.append

    name = report.header.get("name", "?")
    vers = report.header.get("vers", "?")

    w("=" * 78)
    w("%s %s" % (name, vers))
    w("=" * 78)
    w("%-18s%s" % ("Report:", report.path))
    w("%-18s%s" % ("Identifier:", report.header.get("bund", "?")))
    w("%-18s%s" % ("OS:", report.header.get("soft", "?")))
    w("%-18s%s" % ("Architecture:", report.header.get("arch", "?")))
    w("%-18s%s" % ("UID:", report.header.get("uidn", "?")))

    if report.timestamp:
        stamp = time.strftime("%Y-%m-%d %H:%M:%S %Z", time.localtime(report.timestamp))
        w("%-18s%s (%d)" % ("Date:", stamp, report.timestamp))

    if report.signal_name:
        code = report.signal_code_name
        code_text = "code %d" % (report.sicode or 0)
        if code:
            code_text = "%s (%d)" % (code, report.sicode or 0)

        if report.sicode == SI_USER:
            w("%-18s%s, SI_USER (0): raised by kill() or abort(), not a fault"
              % ("Signal:", report.signal_name))
            w("%-18s0x%x (meaningless for a raised signal)"
              % ("si_addr:", report.siaddr or 0))
        else:
            w("%-18s%s, %s, fault address 0x%x"
              % ("Signal:", report.signal_name, code_text, report.siaddr or 0))

    for key in sorted(report.custom):
        w("%-18s%s" % (key + ":", report.custom[key]))

    if report.exception_name or report.exception_lines:
        w("")
        w("-- Uncaught exception " + "-" * 56)
        if report.exception_name:
            w("Name: %s" % report.exception_name)
        for line in report.exception_lines:
            w("  %s" % line)
        if exception_frames:
            w("Call stack return addresses:")
            for i, frame in enumerate(exception_frames):
                w("  " + format_frame(i, frame))

    for i, thread in enumerate(report.threads):
        w("")
        label = "Thread %d" % i
        if thread.crashed:
            label += " (crashed)"
        w("-- %s %s" % (label, "-" * max(0, 74 - len(label))))
        if thread.note:
            w("   note: %s" % thread.note)
        if not thread.frames:
            w("   (no frames)")
        for j, frame in enumerate(thread.frames):
            w("  " + format_frame(j, frame, crashed=thread.crashed))

    if report.registers:
        w("")
        w("-- Registers (crashed thread) " + "-" * 48)
        names = report.register_names
        row = []
        for nm, value in zip(names, report.registers):
            if nm == "cpsr":
                value &= 0xFFFFFFFF
            row.append("%-6s 0x%016x" % (nm, value))
            if len(row) == 3:
                w("  " + "  ".join(row))
                row = []
        if row:
            w("  " + "  ".join(row))

    if report.images:
        referenced = set()
        for thread in report.threads:
            for frame in thread.frames:
                if frame.image is not None:
                    referenced.add(id(frame.image))
        for frame in exception_frames:
            if frame.image is not None:
                referenced.add(id(frame.image))

        if all_images:
            shown = list(report.images)
            heading = "-- Binary images (all %d) " % len(report.images)
        else:
            shown = [i for i in report.images if id(i) in referenced]
            heading = ("-- Binary images (%d of %d, referenced by a backtrace) "
                       % (len(shown), len(report.images)))

        w("")
        w(heading + "-" * max(0, 78 - len(heading)))
        for image in sorted(shown, key=lambda i: i.addr):
            resolved = "" if image.binary else "  (no symbols on this machine)"
            w("  0x%012x - 0x%012x  %-28s %-8s %s  %s%s"
              % (image.addr, max(image.addr, image.end - 1), image.name[:28],
                 image.arch, image.pretty_uuid, image.path, resolved))

        if not all_images and len(shown) != len(report.images):
            w("  (%d more loaded; pass --all-images to list them)"
              % (len(report.images) - len(shown)))

    messages = report.warnings + symbolizer.notes
    if messages:
        w("")
        w("-- Notes " + "-" * 68)
        for message in messages:
            w("  * %s" % message)

    w("")
    return "\n".join(out)


def default_crashes_dir():
    return os.path.expanduser("~/Library/Application Support/EmbraceNG/Crashes")


def main():
    parser = argparse.ArgumentParser(
        description="Symbolicate on-disk EscapePod crash reports.")
    parser.add_argument("reports", nargs="*",
                        help="report files (default: newest in the crashes directory)")
    parser.add_argument("--all", action="store_true",
                        help="process every report in the crashes directory")
    parser.add_argument("--crashes-dir", default=default_crashes_dir(),
                        help="where reports live (default: %(default)s)")
    parser.add_argument("--search", action="append", default=[], metavar="DIR",
                        help="extra directory to search for binaries and dSYMs (repeatable)")
    parser.add_argument("--all-images", action="store_true",
                        help="list every loaded image, not just those in a backtrace")
    parser.add_argument("-o", "--output", help="write to this file instead of stdout")
    parser.add_argument("-v", "--verbose", action="store_true",
                        help="log symbol lookups to stderr")
    args = parser.parse_args()

    paths = list(args.reports)

    if not paths:
        directory = args.crashes_dir
        if not os.path.isdir(directory):
            sys.stderr.write("No crashes directory at %s\n" % directory)
            return 1

        found = [os.path.join(directory, e) for e in sorted(os.listdir(directory))]
        found = [p for p in found if os.path.isfile(p) and not os.path.basename(p).startswith(".")]

        if not found:
            sys.stderr.write("No reports in %s\n" % directory)
            return 1

        found.sort(key=os.path.getmtime)
        paths = found if args.all else [found[-1]]

    search_paths = [p for p in args.search if os.path.isdir(p)]
    for missing in set(args.search) - set(search_paths):
        sys.stderr.write("Ignoring --search %s: not a directory\n" % missing)

    chunks = []

    for path in paths:
        if not os.path.isfile(path):
            sys.stderr.write("Not a file: %s\n" % path)
            return 1

        report = parse_report(path)
        symbolizer = Symbolizer(search_paths, verbose=args.verbose)
        exception_frames = symbolizer.symbolicate(report)
        chunks.append(render(report, symbolizer, exception_frames,
                             all_images=args.all_images))

    text = "\n".join(chunks)

    if args.output:
        with open(args.output, "w") as f:
            f.write(text)
        sys.stderr.write("Wrote %s\n" % args.output)
    else:
        sys.stdout.write(text)

    return 0


if __name__ == "__main__":
    sys.exit(main())
