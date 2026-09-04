#!/usr/bin/env python3
"""
Synthetic NSZ/NSP test generator for nszcli validation.

Builds pairs of (original NSP, compressed NSZ) covering every decompression
code path, then nszcli's output can be byte-compared against the original NSP.

Usage: make_test_nsz.py <output_dir>
"""
import io
import math
import os
import struct
import sys
import hashlib
import zstandard
from Crypto.Cipher import AES
from Crypto.Util import Counter

OUT = sys.argv[1] if len(sys.argv) > 1 else "testdata"
os.makedirs(OUT, exist_ok=True)


class AESCTR:
    """Verbatim replica of nsz IndependentNczDecompressor.AESCTR"""

    def __init__(self, key, nonce, offset=0):
        self.key = key
        self.nonce = nonce
        self.seek(offset)

    def encrypt(self, data, ctr=None):
        if ctr is None:
            ctr = self.ctr
        return self.aes.encrypt(data)

    def decrypt(self, data, ctr=None):
        return self.encrypt(data, ctr)

    def seek(self, offset):
        self.ctr = Counter.new(64, prefix=self.nonce[0:8], initial_value=(offset >> 4))
        self.aes = AES.new(self.key, AES.MODE_CTR, counter=self.ctr)


def le32(x):
    return struct.pack("<I", x)


def le64(x):
    return struct.pack("<Q", x)


def build_pfs0(files):
    """files: [(name, content)] -> complete PFS0 container bytes"""
    count = len(files)
    names = b"".join(n.encode() + b"\x00" for n, _ in files)
    data_start = 16 + 24 * count + len(names)
    name_offsets = []
    off = 0
    for n, _ in files:
        name_offsets.append(off)
        off += len(n.encode()) + 1
    entry_data = b""
    file_off = 0  # PFS0 spec: entry offsets are relative to data start
    for (n, c), no in zip(files, name_offsets):
        entry_data += le64(file_off) + le64(len(c)) + le32(no) + le32(0)
        file_off += len(c)
    return (
        b"PFS0"
        + le32(count)
        + le32(len(names))
        + b"\x00" * 4
        + entry_data
        + names
        + b"".join(c for _, c in files)
    )


def make_data(total, seed):
    """Mixed compressible + incompressible data."""
    rng = bytearray()
    pattern = bytes(range(256)) * 64
    while len(rng) < total:
        if (len(rng) // (1 << 18)) % 2 == 0:
            rng += pattern  # compressible
        else:
            rng += os.urandom(1 << 18)  # incompressible
    return bytes(rng[:total])


def encrypt_section(plain, offset, key, counter):
    """Encrypt `plain` (which lives at NCA absolute `offset`) - what the original NCA contains."""
    return AESCTR(key, counter, offset).encrypt(plain)


def build_ncz(nca, sections, mode, block_exponent=18):
    """
    sections: [{"offset","size","ctype","key","counter"}] covering the NCA body
    contiguously from the first section to EOF (the compressor's stream covers
    from 0x4000 onward; a FakeSection gap is implied when offset > 0x4000).
    """
    out = bytearray(nca[: 0x4000])
    out += b"NCZSECTN" + le64(len(sections))
    for s in sections:
        out += (
            le64(s["offset"])
            + le64(s["size"])
            + le64(s["ctype"])
            + le64(0)
            + s["key"]
            + s["counter"]
        )
    # plaintext stream: official nsz semantics - the compressor covers the WHOLE
    # NCA body from 0x4000 to EOF (a FakeSection gap after 0x4000 is included as
    # plain bytes). Sections must cover [first.offset, EOF) contiguously.
    adjusted = list(sections)
    if adjusted[0]["offset"] > 0x4000:
        adjusted.insert(
            0,
            {"offset": 0x4000, "size": adjusted[0]["offset"] - 0x4000,
             "ctype": 1, "key": b"", "counter": b""},
        )
    expected_off = adjusted[0]["offset"]
    for s in adjusted:
        if s["offset"] != expected_off:
            raise ValueError(
                f"sections not contiguous at {s['offset']:#x}, expected {expected_off:#x}"
            )
        expected_off = s["offset"] + s["size"]
    if expected_off != len(nca):
        raise ValueError(
            f"sections end at {expected_off:#x} but NCA size is {len(nca):#x}"
        )
    stream = b""
    for s in adjusted:
        chunk = nca[s["offset"] : s["offset"] + s["size"]]
        if s["ctype"] in (3, 4):
            chunk = AESCTR(s["key"], s["counter"], s["offset"]).encrypt(chunk)
        stream += chunk

    if mode == "solid":
        cctx = zstandard.ZstdCompressor(level=3)
        out += cctx.compress(stream)
    elif mode == "block":
        bs = 1 << block_exponent
        nblocks = math.ceil(len(stream) / bs)
        sizes = []
        blocks = b""
        for i in range(nblocks):
            d = stream[i * bs : (i + 1) * bs]
            dsize = bs if i < nblocks - 1 else len(stream) - i * bs
            comp = zstandard.ZstdCompressor(level=3).compress(d)
            if len(comp) < dsize:
                sizes.append(len(comp))
                blocks += comp
            else:  # stored in plain text (cbs >= dSize)
                sizes.append(dsize)
                blocks += d
        out += (
            b"NCZBLOCK"
            + bytes([0, 0, 0, block_exponent])
            + le32(nblocks)
            + le64(len(stream))
            + b"".join(le32(x) for x in sizes)
        )
        out += blocks
    else:
        raise ValueError(mode)
    return bytes(out)


def write_case(name, files_nsp, files_nsz):
    """files_*: [(name, content)] - writes <name>.nsp (original) and <name>.nsz"""
    nsp = build_pfs0(files_nsp)
    nsz = build_pfs0(files_nsz)
    with open(os.path.join(OUT, name + ".nsp"), "wb") as f:
        f.write(nsp)
    with open(os.path.join(OUT, name + ".nsz"), "wb") as f:
        f.write(nsz)
    print(f"[gen] {name}: nsp={len(nsp)} nsz={len(nsz)}")


def random_key():
    return os.urandom(16)


def random_counter():
    # nsz semantics: counter[0:8] = prefix, counter[8:16] unused
    return os.urandom(8) + b"\x00" * 8


# ---------------------------------------------------------------- test A
# solid zstd, 2 contiguous sections, cryptoType 3
dataA = make_data(0x200000, 1)
key1, key2 = random_key(), random_key()
ctr1, ctr2 = random_counter(), random_counter()
nca_a = (
    os.urandom(0x4000)
    + encrypt_section(dataA[: 0x100000], 0x4000, key1, ctr1)
    + encrypt_section(dataA[0x100000:], 0x104000, key2, ctr2)
)
sections_a = [
    {"offset": 0x4000, "size": 0x100000, "ctype": 3, "key": key1, "counter": ctr1},
    {"offset": 0x104000, "size": 0x100000, "ctype": 3, "key": key2, "counter": ctr2},
]
name_a = hashlib.sha256(nca_a).hexdigest()[:32] + ".nca"
ncz_a = build_ncz(nca_a, sections_a, "solid")
write_case(
    "testA_solid_2sections",
    [(name_a, nca_a)],
    [(name_a[:-4] + ".ncz", ncz_a)],
)

# ---------------------------------------------------------------- test B
# block mode, last-block remainder, stored-plain blocks (random data), type 4
dataB = make_data(0x310000, 2)  # 0x310000 % 0x40000 = 0x10000 remainder
keyB, ctrB = random_key(), random_counter()
nca_b = os.urandom(0x4000) + encrypt_section(dataB, 0x4000, keyB, ctrB)
sections_b = [
    {"offset": 0x4000, "size": 0x310000, "ctype": 4, "key": keyB, "counter": ctrB},
]
name_b = hashlib.sha256(nca_b).hexdigest()[:32] + ".nca"
ncz_b = build_ncz(nca_b, sections_b, "block", block_exponent=18)
write_case(
    "testB_block_type4",
    [(name_b, nca_b)],
    [(name_b[:-4] + ".ncz", ncz_b)],
)

# ---------------------------------------------------------------- test C
# FakeSection: first section starts at 0x6000 (gap between 0x4000 and 0x6000)
gap = os.urandom(0x2000)
dataC = make_data(0x300000, 3)
keyC, ctrC = random_key(), random_counter()
nca_c = os.urandom(0x4000) + gap + encrypt_section(dataC, 0x6000, keyC, ctrC)
sections_c = [
    {"offset": 0x6000, "size": 0x300000, "ctype": 3, "key": keyC, "counter": ctrC},
]
name_c = hashlib.sha256(nca_c).hexdigest()[:32] + ".nca"
ncz_c = build_ncz(nca_c, sections_c, "solid")
write_case(
    "testC_fake_section",
    [(name_c, nca_c)],
    [(name_c[:-4] + ".ncz", ncz_c)],
)

# ---------------------------------------------------------------- test D
# multi-entry: plain .nca + non-hash-named file + one .ncz
plain_nca = os.urandom(0x4000) + make_data(0x80000, 4)
other = b"cnmt-ish plain content \x00" * 1000
name_d1 = hashlib.sha256(plain_nca).hexdigest()[:32] + ".nca"
name_d2 = "control.nasp"  # not hash-named
ncz_core = build_ncz(
    nca_a, sections_a, "solid"
)  # reuse A's nca/ncz content
write_case(
    "testD_multi_entry",
    [(name_d1, plain_nca), (name_d2, other), (name_a, nca_a)],
    [(name_d1, plain_nca), (name_d2, other), (name_a[:-4] + ".ncz", ncz_core)],
)

# ---------------------------------------------------------------- test E
# solid stream with high zstd level + block exponent 32 (1 GB blocks, single block)
dataE = make_data(0x150000, 5)  # < 2^32 exponent-32 block size but multiple blocks at 2^18
keyE, ctrE = random_key(), random_counter()
nca_e = os.urandom(0x4000) + encrypt_section(dataE, 0x4000, keyE, ctrE)
sections_e = [
    {"offset": 0x4000, "size": 0x150000, "ctype": 3, "key": keyE, "counter": ctrE},
]
name_e = hashlib.sha256(nca_e).hexdigest()[:32] + ".nca"
ncz_e = build_ncz(nca_e, sections_e, "block", block_exponent=21)  # 2MB block > data
write_case(
    "testE_block_single",
    [(name_e, nca_e)],
    [(name_e[:-4] + ".ncz", ncz_e)],
)

print("[gen] all test cases written to", os.path.abspath(OUT))
