#!/usr/bin/env python3
"""Fix HDF5 async GOTCHA wrappers to match actual HDF5 symbol signatures.

HDF5 >= 1.13 async functions have 3 extra params (app_file, app_func, app_line)
in the actual symbol, but brahma uses the H5_DOXYGEN simplified declarations
without these params. This causes ABI mismatch when GOTCHA intercepts the
real function calls at the symbol/PLT level.

This script:
1. Patches brahma's interceptor.h with a new GOTCHA_MACRO_TYPEDEF_ASYNC macro
2. Patches brahma's hdf5.h to use the new macro for async functions
3. Patches dftracer's hdf5.cpp to pass file/func/line to __real_ calls

Usage:
    python3 fix_async_wrappers.py <interceptor.h> <brahma_hdf5.h> <dftracer_hdf5.cpp>
"""

import re
import sys


def parse_macro_call(text, start_pos):
    """Extract a complete macro call starting at start_pos, handling nested parens.
    Returns (full_text, args_list) where args_list is the top-level arguments."""
    # Find opening paren
    paren_start = text.index('(', start_pos)
    depth = 0
    i = paren_start
    while i < len(text):
        if text[i] == '(':
            depth += 1
        elif text[i] == ')':
            depth -= 1
            if depth == 0:
                full = text[start_pos:i + 1]
                inner = text[paren_start + 1:i]
                args = split_top_level(inner)
                return full, args
        i += 1
    return None, None


def split_top_level(text):
    """Split text by commas at the top level (depth 0 for parens)."""
    args = []
    current = []
    depth = 0
    for ch in text:
        if ch in '([':
            depth += 1
            current.append(ch)
        elif ch in ')]':
            depth -= 1
            current.append(ch)
        elif ch == ',' and depth == 0:
            args.append(''.join(current).strip())
            current = []
        else:
            current.append(ch)
    if current:
        args.append(''.join(current).strip())
    return args


def extract_param_names(param_decl_str):
    """Extract parameter names from a parenthesized declaration string.
    E.g. '(hid_t loc_id, const char *name)' -> ['loc_id', 'name']"""
    # Remove outer parens
    s = param_decl_str.strip()
    if s.startswith('(') and s.endswith(')'):
        s = s[1:-1].strip()
    if not s:
        return []
    params = split_top_level(s)
    names = []
    for p in params:
        p = p.strip()
        if not p:
            continue
        # Handle array params like "hid_t dset_id[]"
        if '[]' in p:
            # Extract name before []
            m = re.search(r'(\w+)\s*\[\]', p)
            if m:
                names.append(m.group(1))
                continue
        # Handle function pointer params
        if '(*)' in p:
            m = re.search(r'\(\*(\w+)\)', p)
            if m:
                names.append(m.group(1))
                continue
        # Regular param: last word, possibly preceded by *
        tokens = p.replace('*', ' * ').split()
        name = tokens[-1].lstrip('*')
        names.append(name)
    return names


def has_app_line_first(param_decl_str):
    """Check if the first parameter is named 'app_line'."""
    names = extract_param_names(param_decl_str)
    return len(names) > 0 and names[0] == 'app_line'


def patch_interceptor(filepath):
    """Add GOTCHA_MACRO_TYPEDEF_ASYNC macro to interceptor.h."""
    with open(filepath) as f:
        content = f.read()

    marker = 'GOTCHA_MACRO_TYPEDEF_ASYNC'
    if marker in content:
        print(f"  interceptor.h: GOTCHA_MACRO_TYPEDEF_ASYNC already present, skipping.")
        return

    new_macro = r"""
#define GOTCHA_MACRO_TYPEDEF_ASYNC(macroname, macroret, macroargs_full, macro2args_full_val, macro2args_user_val, macroclass_name) \
  typedef macroret(*macroname##_fptr) macroargs_full;                                                    \
  macroret __attribute__((weak)) macroname macroargs_full;                                               \
  inline macroret macroname##_wrapper macroargs_full {                                                   \
    auto instance = macroclass_name::get_instance();                                                     \
    if (instance == nullptr) {                                                                           \
      macroname##_fptr fn = &::macroname;                                                                \
      return fn macro2args_full_val;                                                                     \
    }                                                                                                    \
    return instance->macroname macro2args_user_val;                                                      \
  }
"""

    # Insert before #endif at the end
    content = content.rstrip()
    if content.endswith('#endif  // BRAHMA_INTERCEPTOR_H'):
        content = content[:-len('#endif  // BRAHMA_INTERCEPTOR_H')]
        content += new_macro + '\n#endif  // BRAHMA_INTERCEPTOR_H\n'
    elif content.endswith('#endif'):
        content = content[:-len('#endif')]
        content += new_macro + '\n#endif\n'
    else:
        content += new_macro

    with open(filepath, 'w') as f:
        f.write(content)
    print(f"  interceptor.h: Added GOTCHA_MACRO_TYPEDEF_ASYNC macro.")


def patch_brahma_header(filepath):
    """Convert GOTCHA_MACRO_TYPEDEF for async functions to GOTCHA_MACRO_TYPEDEF_ASYNC."""
    with open(filepath) as f:
        content = f.read()

    # Find all GOTCHA_MACRO_TYPEDEF calls for *_async functions
    pattern = re.compile(r'GOTCHA_MACRO_TYPEDEF\s*\(\s*(H5\w+_async)\s*,')
    replacements = []

    for m in pattern.finditer(content):
        func_name = m.group(1)
        full_text, args = parse_macro_call(content, m.start())
        if full_text is None or len(args) < 5:
            print(f"  WARNING: Could not parse GOTCHA_MACRO_TYPEDEF for {func_name}")
            continue

        # args: [name, ret_type, (params), (param_vals), class]
        name = args[0].strip()
        ret_type = args[1].strip()
        param_decl = args[2].strip()    # e.g. "(hid_t loc_id, ...)"
        param_vals = args[3].strip()    # e.g. "(loc_id, ...)"
        cls = args[4].strip()           # e.g. "brahma::HDF5"

        # Remove trailing semicolon from class if present
        cls = cls.rstrip(';').strip()

        # Determine if this function already has app_line in its Doxygen params
        app_line_first = has_app_line_first(param_decl)

        # Build the full (real HDF5 symbol) parameter declarations
        inner_decl = param_decl.strip()
        if inner_decl.startswith('('):
            inner_decl = inner_decl[1:]
        if inner_decl.endswith(')'):
            inner_decl = inner_decl[:-1]
        inner_decl = inner_decl.strip()

        inner_vals = param_vals.strip()
        if inner_vals.startswith('('):
            inner_vals = inner_vals[1:]
        if inner_vals.endswith(')'):
            inner_vals = inner_vals[:-1]
        inner_vals = inner_vals.strip()

        if app_line_first:
            # H5Ropen_object_async case: Doxygen has app_line, real adds app_file + app_func
            full_decl = f"(const char *_brahma_file, const char *_brahma_func, {inner_decl})"
            full_vals = f"(_brahma_file, _brahma_func, {inner_vals})"
        else:
            # Standard case: add all 3 extra params
            full_decl = f"(const char *_brahma_file, const char *_brahma_func, unsigned _brahma_line, {inner_decl})"
            full_vals = f"(_brahma_file, _brahma_func, _brahma_line, {inner_vals})"

        user_vals = param_vals  # Original param values for instance method call

        new_call = (
            f"GOTCHA_MACRO_TYPEDEF_ASYNC({name}, {ret_type},\n"
            f"                     {full_decl},\n"
            f"                     {full_vals},\n"
            f"                     {user_vals},\n"
            f"                     {cls});"
        )

        # Track the full text to replace (including trailing semicolon)
        end_pos = m.start() + len(full_text)
        # Skip trailing semicolon if present
        remaining = content[end_pos:end_pos + 5]
        if remaining.lstrip().startswith(';'):
            # full_text already ends with ), need to include the ;
            semi_offset = remaining.index(';')
            full_with_semi = content[m.start():end_pos + semi_offset + 1]
        else:
            full_with_semi = full_text

        replacements.append((full_with_semi, new_call))

    if not replacements:
        print(f"  brahma hdf5.h: No GOTCHA_MACRO_TYPEDEF async calls found (already patched?).")
        return

    # Apply replacements (reverse order to preserve positions)
    for old, new in reversed(replacements):
        content = content.replace(old, new, 1)

    with open(filepath, 'w') as f:
        f.write(content)
    print(f"  brahma hdf5.h: Converted {len(replacements)} GOTCHA_MACRO_TYPEDEF -> GOTCHA_MACRO_TYPEDEF_ASYNC.")


def patch_dftracer_cpp(filepath, brahma_header_path):
    """Add dummy file/func/line args to __real_H5*_async() calls in dftracer."""
    with open(filepath) as f:
        content = f.read()

    # First, determine which async functions have app_line in their brahma signature
    with open(brahma_header_path) as f:
        brahma_content = f.read()

    # Find functions where brahma's virtual method has app_line as first param
    app_line_funcs = set()
    virt_pattern = re.compile(
        r'virtual\s+\w+\s+(H5\w+_async)\s*\(([^)]+)\)'
    )
    for m in virt_pattern.finditer(brahma_content):
        func_name = m.group(1)
        params = m.group(2).strip()
        first_param = params.split(',')[0].strip()
        if 'app_line' in first_param:
            app_line_funcs.add(func_name)

    # Find and patch all __real_H5*_async( calls
    real_pattern = re.compile(r'(__real_(H5\w+_async))\s*\(')
    count = 0
    offset = 0

    matches = list(real_pattern.finditer(content))
    new_content = content

    for m in reversed(matches):
        func_call = m.group(1)
        func_name = m.group(2)
        paren_pos = m.end() - 1  # Position of '('

        # Check what follows the opening paren
        after_paren = new_content[paren_pos + 1:paren_pos + 30]

        # Skip if already patched
        if after_paren.lstrip().startswith('"'):
            continue

        if func_name in app_line_funcs:
            # Only add app_file and app_func (app_line is already the first user arg)
            insert = '"", "", '
        else:
            # Add all 3 extra params
            insert = '"", "", 0, '

        new_content = new_content[:paren_pos + 1] + insert + new_content[paren_pos + 1:]
        count += 1

    if count == 0:
        print(f"  dftracer hdf5.cpp: No __real_ async calls to patch (already patched?).")
        return

    with open(filepath, 'w') as f:
        f.write(new_content)
    print(f"  dftracer hdf5.cpp: Added file/func/line args to {count} __real_ async calls.")


def main():
    if len(sys.argv) != 4:
        print(f"Usage: {sys.argv[0]} <interceptor.h> <brahma_hdf5.h> <dftracer_hdf5.cpp>")
        sys.exit(1)

    interceptor_h = sys.argv[1]
    brahma_hdf5_h = sys.argv[2]
    dftracer_cpp = sys.argv[3]

    print("Fixing HDF5 async GOTCHA wrapper ABI mismatch...")
    patch_interceptor(interceptor_h)
    patch_brahma_header(brahma_hdf5_h)
    patch_dftracer_cpp(dftracer_cpp, brahma_hdf5_h)
    print("Done.")


if __name__ == '__main__':
    main()
