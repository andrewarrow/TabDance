#!/usr/bin/env python3
"""Repeatable, dependency-free static extraction for the supplied Terminal Mach-O."""
from __future__ import annotations
import csv
import bisect
import hashlib
import json
import os
import plistlib
import re
import shlex
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

SOURCE = Path('/Users/aa/Downloads/term.bin.exe.mac')
BUNDLE = Path('/System/Applications/Utilities/Terminal.app')
EXECUTABLE = BUNDLE / 'Contents/MacOS/Terminal'
ROOT = Path(__file__).resolve().parent
RAW = ROOT / 'raw'
THIN = RAW / 'Terminal.arm64e.macho'

TOOLS = {
    'file': [['file', str(SOURCE)], ['file', str(THIN)]],
    'lipo_archs': [['lipo', '-archs', str(SOURCE)]],
    'lipo_details': [['lipo', '-detailed_info', str(SOURCE)]],
    'codesign': [['codesign', '-dvvv', str(SOURCE)]],
    'otool_header': [['otool', '-hv', str(THIN)]],
    'otool_load_commands': [['otool', '-l', str(THIN)]],
    'otool_linked_libraries': [['otool', '-L', str(THIN)]],
    'nm_symbols': [['nm', '-m', str(THIN)]],
    'dyld_platform': [['dyld_info', '-arch', 'arm64e', '-platform', str(THIN)]],
    'dyld_segments': [['dyld_info', '-arch', 'arm64e', '-segments', str(THIN)]],
    'dyld_linked_dylibs': [['dyld_info', '-arch', 'arm64e', '-linked_dylibs', str(THIN)]],
    'dyld_inits': [['dyld_info', '-arch', 'arm64e', '-inits', str(THIN)]],
    'dyld_exports': [['dyld_info', '-arch', 'arm64e', '-exports', str(THIN)]],
    'dyld_imports': [['dyld_info', '-arch', 'arm64e', '-imports', str(THIN)]],
    'dyld_objc': [['dyld_info', '-arch', 'arm64e', '-objc', str(THIN)]],
    'dyld_fixups': [['dyld_info', '-arch', 'arm64e', '-fixups', str(THIN)]],
    'dyld_fixup_chains': [['dyld_info', '-arch', 'arm64e', '-fixup_chains', str(THIN)]],
    'dyld_function_starts': [['dyld_info', '-arch', 'arm64e', '-function_starts', str(THIN)]],
    'dyld_uuid': [['dyld_info', '-arch', 'arm64e', '-uuid', str(THIN)]],
    'dyld_disassembly': [['dyld_info', '-arch', 'arm64e', '-disassemble', str(THIN)]],
    'dyld_cstrings': [['dyld_info', '-arch', 'arm64e', '-section', '__TEXT', '__cstring', str(THIN)]],
    'dyld_objc_selectors': [['dyld_info', '-arch', 'arm64e', '-section', '__TEXT', '__objc_methname', str(THIN)]],
    'dyld_objc_classnames': [['dyld_info', '-arch', 'arm64e', '-section', '__TEXT', '__objc_classname', str(THIN)]],
    'dyld_objc_method_types': [['dyld_info', '-arch', 'arm64e', '-section', '__TEXT', '__objc_methtype', str(THIN)]],
}


def sha256(path: Path) -> str:
    h = hashlib.sha256()
    with path.open('rb') as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b''):
            h.update(chunk)
    return h.hexdigest()


def run_capture(name: str, argv: list[str]) -> dict:
    p = subprocess.run(argv, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, errors='replace')
    # Several macOS inspection tools (notably codesign -d) intentionally write
    # their useful report to stderr; preserve both streams in the primary dump.
    (RAW / f'{name}.txt').write_text(p.stdout + p.stderr, encoding='utf-8')
    (RAW / f'{name}.stderr.txt').write_text(p.stderr, encoding='utf-8')
    return {'argv': argv, 'exit_code': p.returncode, 'stdout_file': f'raw/{name}.txt', 'stderr_file': f'raw/{name}.stderr.txt'}


def parse_objc(text: str) -> tuple[list[dict], list[dict], list[dict]]:
    classes = []
    categories = []
    methods = []
    current = None
    class_re = re.compile(r'^\s*@interface\s+(\w+)\s*:\s*(\S+)')
    category_re = re.compile(r'^\s*@interface\s+(\w+)\(([^)]*)\)')
    method_re = re.compile(r'^\s*(0x[0-9A-Fa-f]+)\s+([+-]\[[^\]]+\])\s*$')
    for line in text.splitlines():
        km = category_re.match(line)
        cm = class_re.match(line)
        if km:
            current = {'name': km.group(1), 'category': km.group(2), 'kind': 'category', 'methods': []}
            categories.append(current)
            continue
        if cm:
            current = {'name': cm.group(1), 'superclass': cm.group(2), 'kind': 'class', 'methods': []}
            classes.append(current)
            continue
        mm = method_re.match(line)
        if mm:
            rec = {'address': int(mm.group(1), 16), 'address_hex': mm.group(1).lower(), 'name': mm.group(2), 'class': current['name'] if current else None, 'category': current.get('category') if current else None, 'interface_kind': current.get('kind') if current else None}
            methods.append(rec)
            if current is not None:
                current['methods'].append(rec['name'])
    return classes, categories, methods


def parse_calls(text: str, methods: list[dict]) -> list[dict]:
    address_to_methods: dict[int, list[str]] = {}
    for method in methods:
        address_to_methods.setdefault(method['address'], []).append(method['name'])
    label_re = re.compile(r'^([^\n]+):\s*$')
    insn_re = re.compile(r'^\s*(0x[0-9A-Fa-f]+)\s+(bl|b)\s+(.+?)\s*$')
    current = None
    calls: list[dict] = []
    for line in text.splitlines():
        lm = label_re.match(line)
        if lm and not lm.group(1).strip().startswith('0x'):
            current = lm.group(1).strip()
            continue
        im = insn_re.match(line)
        if not im or current is None:
            continue
        target = im.group(3).strip()
        target_clean = target.split(';', 1)[0].strip()
        # Preserve tool's textual destination and only classify mechanically.
        imported = re.search(r'(_objc_msgSend\$[^\s"]+|_[A-Za-z0-9_.$?]+)', target_clean)
        hex_addr = re.search(r'0x[0-9A-Fa-f]+', target_clean)
        resolved = int(hex_addr.group(0), 16) if hex_addr else None
        calls.append({
            'caller': current,
            'instruction_address': int(im.group(1), 16),
            'instruction_address_hex': im.group(1).lower(),
            'instruction': im.group(2),
            'target_text': target_clean.strip('"'),
            'target_symbol': imported.group(1) if imported else None,
            'target_address': resolved,
            'target_methods': address_to_methods.get(resolved, []) if resolved is not None else [],
        })
    return calls


def parse_function_starts(text: str) -> list[int]:
    return sorted({int(x, 16) for x in re.findall(r'^\s*(0x[0-9A-Fa-f]+)\s+__TEXT,__text', text, re.M)})


def method_ranges(methods: list[dict], starts: list[int]) -> list[dict]:
    """Bound each Objective-C method at the next LC_FUNCTION_STARTS entry."""
    ranges = []
    for method in methods:
        next_start = next((addr for addr in starts if addr > method['address']), None)
        ranges.append({**method, 'range_end': next_start, 'range_end_hex': f'0x{next_start:x}' if next_start is not None else None})
    return ranges


def parse_instructions(text: str) -> list[dict]:
    instruction_re = re.compile(r'^\s*(0x[0-9A-Fa-f]+)\s+([A-Za-z][A-Za-z0-9.]*)\s*(.*?)\s*$')
    result = []
    for line in text.splitlines():
        match = instruction_re.match(line)
        if match:
            result.append({'address': int(match.group(1), 16), 'address_hex': match.group(1).lower(), 'mnemonic': match.group(2), 'operands': match.group(3).strip(), 'line': line.rstrip()})
    return result


def method_calls(methods: list[dict], starts: list[int], instructions: list[dict]) -> list[dict]:
    address_to_methods: dict[int, list[str]] = {}
    for method in methods:
        address_to_methods.setdefault(method['address'], []).append(method['name'])
    instruction_addresses = [i['address'] for i in instructions]
    result = []
    for method in method_ranges(methods, starts):
        end = method['range_end']
        first = bisect.bisect_left(instruction_addresses, method['address'])
        last = bisect.bisect_left(instruction_addresses, end) if end is not None else len(instructions)
        owned = instructions[first:last]
        edges = []
        for insn in owned:
            if insn['mnemonic'] not in ('bl', 'b'):
                continue
            target = insn['operands'].split(';', 1)[0].strip()
            symbol = re.search(r'(_objc_msgSend\$[^\s"]+|_[A-Za-z0-9_.$?]+)', target)
            target_addr_match = re.search(r'0x[0-9A-Fa-f]+', target)
            target_addr = int(target_addr_match.group(0), 16) if target_addr_match else None
            edges.append({'instruction_address': insn['address_hex'], 'instruction': insn['mnemonic'], 'target_text': target.strip('"'), 'target_symbol': symbol.group(1) if symbol else None, 'target_address': f'0x{target_addr:x}' if target_addr is not None else None, 'target_methods': address_to_methods.get(target_addr, []) if target_addr is not None else []})
        result.append({**method, 'instruction_count': len(owned), 'calls': edges})
    return result


def main() -> int:
    if not SOURCE.is_file():
        raise SystemExit(f'missing input binary: {SOURCE}')
    RAW.mkdir(parents=True, exist_ok=True)
    source_hash_before = sha256(SOURCE)
    # Resolve exactly the requested thin architecture and leave the source untouched.
    subprocess.run(['lipo', str(SOURCE), '-thin', 'arm64e', '-output', str(THIN)], check=True)
    command_records = {}
    for name, commands in TOOLS.items():
        # Some evidence files refer to the universal source; all other commands target the thin slice.
        command_records[name] = run_capture(name, commands[0])
    objc_text = (RAW / 'dyld_objc.txt').read_text(encoding='utf-8', errors='replace')
    disassembly = (RAW / 'dyld_disassembly.txt').read_text(encoding='utf-8', errors='replace')
    function_starts_text = (RAW / 'dyld_function_starts.txt').read_text(encoding='utf-8', errors='replace')
    classes, categories, methods = parse_objc(objc_text)
    starts = parse_function_starts(function_starts_text)
    instructions = parse_instructions(disassembly)
    bounded_methods = method_calls(methods, starts, instructions)
    calls = [call for method in bounded_methods for call in method['calls']]
    # Keep duplicates and report them explicitly rather than overwriting by selector/name.
    address_counts = {}
    name_counts = {}
    for method in methods:
        address_counts[method['address_hex']] = address_counts.get(method['address_hex'], 0) + 1
        name_counts[method['name']] = name_counts.get(method['name'], 0) + 1
    metadata = {
        'source': str(SOURCE),
        'thin_binary': 'raw/Terminal.arm64e.macho',
        'classes': classes,
        'class_count': len(classes),
        'categories': categories,
        'category_count': len(categories),
        'interface_count': len(classes) + len(categories),
        'methods': methods,
        'function_start_count': len(starts),
        'method_count': len(methods),
        'duplicate_method_names': {k: v for k, v in name_counts.items() if v > 1},
        'duplicate_method_addresses': {k: v for k, v in address_counts.items() if v > 1},
        'call_map_note': 'Each method range begins at its Objective-C metadata address and ends at the next LC_FUNCTION_STARTS address. Branch targets are tool-rendered text and address matches only; no semantic interpretation.',
    }
    (ROOT / 'objc.json').write_text(json.dumps(metadata, indent=2, sort_keys=True) + '\n', encoding='utf-8')
    with (ROOT / 'objc_methods.tsv').open('w', encoding='utf-8', newline='') as f:
        w = csv.writer(f, delimiter='\t', lineterminator='\n')
        w.writerow(['address', 'class', 'category', 'interface_kind', 'method'])
        for m in methods:
            w.writerow([m['address_hex'], m['class'] or '', m['category'] or '', m['interface_kind'] or '', m['name']])
    with (ROOT / 'calls.json').open('w', encoding='utf-8') as f:
        json.dump({'source_disassembly': 'raw/dyld_disassembly.txt', 'source_function_starts': 'raw/dyld_function_starts.txt', 'method_range_rule': 'Objective-C metadata address through (excluding) the next LC_FUNCTION_STARTS address', 'call_count': len(calls), 'methods': bounded_methods}, f, indent=2, sort_keys=True)
        f.write('\n')
    selected_prefixes = [
        '-[TTShell initWithAction:', '-[TTIOManager init]', '-[TTIOManager IOThread]', '-[TTIOManager mainThread]', '-[TTIOManager writeData:forShell:]',
        '-[TTTabController shellDidReceiveData:]', '-[TTEncodingConverter alignData:', '-[TTEncodingConverter decodeData:]',
        '-[TTVT100Emulator decodeData:]', '-[TTVT100Emulator performOperatingSystemCommand]', '-[TTVT100Emulator encodeKeyDownEvent:]',
        '-[TTLogicalScreen displayWidthForCharacter:]', '-[TTShell updateContentSize:', '-[TTView drawAttributedString:', '-[TTView readSelectionFromString:',
    ]
    methods_dir = ROOT / 'methods'
    methods_dir.mkdir(exist_ok=True)
    selected = []
    for method in bounded_methods:
        if any(method['name'].startswith(prefix) for prefix in selected_prefixes):
            end = method['range_end']
            owned = [i for i in instructions if i['address'] >= method['address'] and (end is None or i['address'] < end)]
            slug = re.sub(r'[^A-Za-z0-9_.-]+', '_', method['name']).strip('_')
            dest = methods_dir / f"{method['address_hex'][2:]}_{slug}.txt"
            dest.write_text(method['name'] + '\n' + '\n'.join(i['line'] for i in owned) + '\n', encoding='utf-8')
            selected.append({'name': method['name'], 'address': method['address_hex'], 'end_exclusive': method['range_end_hex'], 'instruction_count': len(owned), 'file': f'methods/{dest.name}'})
    (ROOT / 'selected_methods.json').write_text(json.dumps({'range_source': 'raw/dyld_function_starts.txt', 'methods': selected}, indent=2, sort_keys=True) + '\n', encoding='utf-8')
    bundle_info = None
    info_path = BUNDLE / 'Contents/Info.plist'
    if info_path.is_file():
        with info_path.open('rb') as f:
            bundle_info = plistlib.load(f)
        (ROOT / 'installed_bundle_info.json').write_text(json.dumps(bundle_info, indent=2, sort_keys=True, default=str) + '\n', encoding='utf-8')
    source_hash_after = sha256(SOURCE)
    installed = {'path': str(EXECUTABLE), 'exists': EXECUTABLE.is_file()}
    if EXECUTABLE.is_file():
        installed.update({'size_bytes': EXECUTABLE.stat().st_size, 'sha256': sha256(EXECUTABLE), 'same_bytes_as_input': sha256(EXECUTABLE) == source_hash_after})
    manifest = {
        'generated_utc': datetime.now(timezone.utc).isoformat(),
        'generator': 'analysis/extract.py (Python standard library; macOS command line tools)',
        'input': {'path': str(SOURCE), 'size_bytes': SOURCE.stat().st_size, 'sha256_before': source_hash_before, 'sha256_after': source_hash_after, 'unchanged_during_extraction': source_hash_before == source_hash_after},
        'installed_bundle': {'path': str(BUNDLE), 'executable': installed, 'bundle_identifier': bundle_info.get('CFBundleIdentifier') if isinstance(bundle_info, dict) else None, 'bundle_version': bundle_info.get('CFBundleVersion') if isinstance(bundle_info, dict) else None, 'same_binary_claim': 'Exact hash comparison of installed executable and supplied input; see same_bytes_as_input.'},
        'thin_slice': {'path': 'raw/Terminal.arm64e.macho', 'size_bytes': THIN.stat().st_size, 'sha256': sha256(THIN), 'architecture': 'arm64e'},
        'objective_c': {'class_count': len(classes), 'category_count': len(categories), 'interface_count': len(classes) + len(categories), 'method_count': len(methods), 'class_file': 'objc.json', 'method_index': 'objc_methods.tsv'},
        'calls': {'count': len(calls), 'file': 'calls.json'},
        'tool_outputs': command_records,
        'notes': ['Static inspection only; the supplied executable was not run.', 'Raw command output is stored under analysis/raw.', 'Repeated Objective-C names and addresses remain separate records and are counted in objc.json.'],
    }
    (ROOT / 'manifest.json').write_text(json.dumps(manifest, indent=2, sort_keys=True) + '\n', encoding='utf-8')
    print(json.dumps({'input_sha256': source_hash_after, 'input_unchanged': source_hash_before == source_hash_after, 'thin_sha256': manifest['thin_slice']['sha256'], 'classes': len(classes), 'methods': len(methods), 'calls': len(calls), 'installed_same_bytes': installed.get('same_bytes_as_input'), 'outputs': len(command_records)}, indent=2))
    return 0

if __name__ == '__main__':
    try:
        raise SystemExit(main())
    except subprocess.CalledProcessError as e:
        print(f'command failed ({e.returncode}): {shlex.join(e.cmd)}', file=sys.stderr)
        raise
