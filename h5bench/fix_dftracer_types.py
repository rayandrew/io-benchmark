#!/usr/bin/env python3
"""Fix type mismatches between brahma base class and dftracer derived class.

libclang resolves C typedef/enum/struct types to their underlying 'int' type
when generating dftracer interface code. This script reads the correct virtual
method signatures from brahma's installed header and patches the dftracer
generated source files (hdf5.h and hdf5.cpp) to match.

Usage:
    python3 fix_dftracer_types.py <brahma_header> <dftracer_h> <dftracer_cpp>
"""

import re
import sys


def collapse_continuations(text):
    """Collapse multi-line C++ declarations into single lines.

    Joins lines where a declaration continues (line doesn't end with
    ; or { or } or #endif or is a preprocessor directive).
    """
    lines = text.split("\n")
    result = []
    buf = ""
    in_decl = False

    for line in lines:
        stripped = line.strip()

        if in_decl:
            buf += " " + stripped
            # Check if this line ends the declaration
            if (";" in stripped or stripped.endswith("{") or
                    stripped.endswith("}")):
                result.append(buf)
                buf = ""
                in_decl = False
            continue

        # Skip preprocessor directives and comments
        if stripped.startswith("#") or stripped.startswith("//"):
            result.append(stripped)
            continue

        # Check if this looks like the start of a multi-line declaration
        # (has a return type and function name with opening paren,
        #  but doesn't end with ; or { or })
        if (re.search(r'\w+\s+\w+\s*\(', stripped) and
                not stripped.endswith(";") and
                not stripped.endswith("{") and
                not stripped.endswith("}") and
                "(" in stripped):
            buf = stripped
            in_decl = True
            continue

        result.append(stripped)

    if buf:
        result.append(buf)

    return "\n".join(result)


def extract_brahma_methods(text):
    """Extract virtual method signatures from brahma header.

    Returns dict: (method_name, param_count) -> normalized_params
    If multiple entries exist for same key, last one wins (highest version).
    """
    collapsed = collapse_continuations(text)
    methods = {}

    # Match: virtual <return_type> <name>(<params>);
    pat = re.compile(r'virtual\s+\w+\s+(H5\w+)\s*\(([^)]*)\)\s*;')

    for m in pat.finditer(collapsed):
        name = m.group(1)
        params = re.sub(r'\s+', ' ', m.group(2).strip())
        param_count = len([p for p in params.split(',') if p.strip()])
        key = (name, param_count)
        # Last entry wins (higher version range in the header)
        methods[key] = params

    return methods


def extract_dftracer_methods(text):
    """Extract override method signatures from dftracer header.

    Returns list of (method_name, param_count, normalized_params)
    """
    collapsed = collapse_continuations(text)
    methods = []

    # Match: <return_type> <name>(<params>) override;
    pat = re.compile(r'\w+\s+(H5\w+)\s*\(([^)]*)\)\s*override\s*;')

    for m in pat.finditer(collapsed):
        name = m.group(1)
        params = re.sub(r'\s+', ' ', m.group(2).strip())
        param_count = len([p for p in params.split(',') if p.strip()])
        methods.append((name, param_count, params))

    return methods


def find_mismatches(brahma_methods, dftracer_methods):
    """Find methods where dftracer params don't match brahma params.

    Returns list of (method_name, old_params, new_params)
    """
    mismatches = []
    for name, param_count, dft_params in dftracer_methods:
        key = (name, param_count)
        if key in brahma_methods:
            brahma_params = brahma_methods[key]
            if dft_params != brahma_params:
                mismatches.append((name, dft_params, brahma_params))
    return mismatches


def apply_fix(text, func_name, old_params, new_params, suffix_pattern):
    """Replace a function's parameter list in the source text.

    Uses flexible whitespace matching to handle multi-line declarations.
    suffix_pattern: regex for what follows the closing paren
                    (e.g., r'\\)\\s*override\\s*;' for header)
    """
    # Build a regex that matches the function name, opening paren,
    # the old params (with flexible whitespace), and the suffix.
    # Split old_params by spaces, escape each token, join with \s+
    old_tokens = old_params.split(' ')
    old_flex = r'\s+'.join(re.escape(tok) for tok in old_tokens if tok)

    pattern = re.compile(
        r'(' + re.escape(func_name) + r'\s*\(\s*)' +
        old_flex +
        r'(\s*' + suffix_pattern + r')',
        re.DOTALL
    )

    # The replacement preserves groups 1 and 2, replacing only params
    # Use a function to avoid backreference issues in new_params
    def replacer(m):
        return m.group(1) + new_params + m.group(2)

    new_text = pattern.sub(replacer, text)
    changed = (new_text != text)
    return new_text, changed


def main():
    if len(sys.argv) != 4:
        print(f"Usage: {sys.argv[0]} <brahma_hdf5.h> <dftracer_hdf5.h> <dftracer_hdf5.cpp>")
        sys.exit(1)

    brahma_path = sys.argv[1]
    dft_h_path = sys.argv[2]
    dft_cpp_path = sys.argv[3]

    with open(brahma_path) as f:
        brahma_text = f.read()
    with open(dft_h_path) as f:
        dft_h_text = f.read()
    with open(dft_cpp_path) as f:
        dft_cpp_text = f.read()

    print("Fixing dftracer HDF5 type mismatches...")

    # Fix _Bool -> bool in all files (_Bool is C99-only, not valid in C++)
    for path, label in [(brahma_path, "brahma"), (dft_h_path, "dftracer .h"),
                         (dft_cpp_path, "dftracer .cpp")]:
        with open(path) as f:
            content = f.read()
        if '_Bool' in content:
            content = content.replace('_Bool', 'bool')
            with open(path, 'w') as f:
                f.write(content)
            print(f"  Fixed _Bool -> bool in {label}")

    # Re-read after _Bool fix
    with open(brahma_path) as f:
        brahma_text = f.read()
    with open(dft_h_path) as f:
        dft_h_text = f.read()
    with open(dft_cpp_path) as f:
        dft_cpp_text = f.read()

    # Extract method signatures
    brahma_methods = extract_brahma_methods(brahma_text)
    dftracer_methods = extract_dftracer_methods(dft_h_text)

    # Find mismatches
    mismatches = find_mismatches(brahma_methods, dftracer_methods)

    if not mismatches:
        print("  All signatures already match.")
        return

    print(f"  Found {len(mismatches)} mismatched signatures:")
    for name, old_p, new_p in mismatches:
        print(f"    {name}")

    # Apply fixes to header and cpp
    h_fixed = 0
    cpp_fixed = 0

    for name, old_params, new_params in mismatches:
        # Fix header: <name>(<params>) override;
        dft_h_text, changed = apply_fix(
            dft_h_text, name, old_params, new_params,
            r'\)\s*override\s*;'
        )
        if changed:
            h_fixed += 1

        # Fix cpp: HDF5DFTracer::<name>(<params>) {
        # We need to match "HDF5DFTracer::" before the function name
        old_tokens = old_params.split(' ')
        old_flex = r'\s+'.join(re.escape(tok) for tok in old_tokens if tok)

        cpp_pattern = re.compile(
            r'(HDF5DFTracer::' + re.escape(name) + r'\s*\(\s*)' +
            old_flex +
            r'(\s*\)\s*\{)',
            re.DOTALL
        )

        def make_replacer(new_p):
            def replacer(m):
                return m.group(1) + new_p + m.group(2)
            return replacer

        new_cpp, changed = dft_cpp_text, False
        dft_cpp_text = cpp_pattern.sub(make_replacer(new_params), dft_cpp_text)
        if dft_cpp_text != new_cpp:
            # We also set changed but don't need to track cpp separately
            pass
        changed = (dft_cpp_text != new_cpp)
        if changed:
            cpp_fixed += 1

    # Write results
    with open(dft_h_path, 'w') as f:
        f.write(dft_h_text)
    with open(dft_cpp_path, 'w') as f:
        f.write(dft_cpp_text)

    print(f"  Fixed {h_fixed} signatures in {dft_h_path}")
    print(f"  Fixed {cpp_fixed} signatures in {dft_cpp_path}")
    print(f"Done.")


if __name__ == "__main__":
    main()
