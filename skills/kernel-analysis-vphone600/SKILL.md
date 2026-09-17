---
name: kernel-analysis-vphone600
description: Analyze vphone600 kernel artifacts using the local symbol database and XNU source tree. Use when working on kernel reverse engineering, address-to-symbol lookup, release-vs-research kernel comparison, or patch analysis for vphone600 variants in this repository.
---

# Kernel Analysis Vphone600

Use the local `research/kernel_info` dataset as the first source of truth for symbol lookup.
Use `research/reference/xnu` as the source-level reference for semantics and structure.

## Required Paths

- `research/kernel_info/kernel_symbols.db`
- `research/kernel_info/kernel_index.tsv`
- `research/kernel_info/json/kernelcache.release.vphone600.bin.symbols.json`
- `research/kernel_info/json/kernelcache.research.vphone600.bin.symbols.json`
- `research/reference/xnu`

If `research/reference/xnu` is missing, create it with a shallow clone:

```bash
mkdir -p research/reference
git clone --depth 1 https://github.com/apple-oss-distributions/xnu.git research/reference/xnu
```

## Workflow

1. Confirm scope is `vphone600` only.
2. Query `kernel_symbols.db` to select `release` or `research` dataset by name.
3. Load the linked JSON symbol file and perform symbol/address lookups.
4. Cross-reference candidate code paths in `research/reference/xnu`.
5. Report findings with explicit kernel name, symbol path, and address.

## Standard Queries

- List known kernels:
  - `sqlite3 research/kernel_info/kernel_symbols.db "select kernel_name, json_path from kernel_symbols order by kernel_name;"`
- Find one kernel by name:
  - `sqlite3 research/kernel_info/kernel_symbols.db "select * from kernel_symbols where kernel_name='kernelcache.release.vphone600';"`
- Search symbol by substring in release JSON:
  - `rg -n 'symbol_name_fragment' research/kernel_info/json/kernelcache.release.vphone600.bin.symbols.json`
- Search symbol by address in research JSON:
  - `rg -n '0xfffffe00...' research/kernel_info/json/kernelcache.research.vphone600.bin.symbols.json`

## Output Rules

- Always include which kernel was used: `kernelcache.release.vphone600` or `kernelcache.research.vphone600`.
- Always include exact symbol name and address when available.
- Always distinguish fact from inference when mapping symbols to XNU behavior.
- Avoid claiming coverage outside vphone600 unless explicitly requested.

## References

- Read `references/kernel-info-queries.md` for reusable SQL and shell query snippets.
