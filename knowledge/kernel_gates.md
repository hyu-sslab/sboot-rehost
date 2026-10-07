# Knowledge table - how to locate kernel security gate patch sites

Derived by `static-analyzer` in `prior` mode and consulted by `fixer-kernel`
during treatment.

**No values are written here.** Offsets differ per kernel, so they must always be
derived (honesty rule 1, never borrow). What lives here is **the procedure**.

## Search procedure per gate

| gate | what it blocks | how to find it |
|---|---|---|
| FIPS-140 POST | halts boot when the crypto self-test fails | `fips` / `crypto` self-test string, to its caller, to the failure `cbnz`/`cbz` |
| DEFEX / KNOX | halts on a vendor integrity policy violation | `defex` string, to `defex_load_rules`, to the mismatch branch |
| SELinux enforce | forces enforcing mode | `sel_write_enforce` symbol, to `cset w8, ne` |
| verified boot / AVB | halts when vbmeta verification fails | `avb` / `vbmeta` string, to the verify return check |
| debug-kinfo early_module | early module loading BUG | `complete_formation`, to the single-slot BUG `cbnz` |

## What to record per site

```
(file_off, expected_word, new_word, why)
```

- A site counts as determined **only once `expected_word` (the pre-image) has been
  confirmed with capstone**. Otherwise leave it as "undetermined - derive later
  from the panic symbol".
- `new_word` is usually `NOP` (`0xD503201F`) or `MOV W0,#0` (`0x52800000`).
- `why` becomes the 이유 field of the bypass record verbatim.

Apply with:
```bash
python3 scripts/patch_kernel.py <workdir>/fw/Image <workdir>/fw/Image.patched \
  <workdir>/kernel_patch_sites.json
```
The sites file is a JSON list of `{"off", "expected", "new", "why"}` (hex strings); no file
means nothing to patch.
`patch_kernel.py` refuses to apply on a pre-image mismatch.

## Bypass record (mandatory for every gate patch)

Each patch gets four fields in `06_machine/bypasses.md`, **written in natural
Korean** because the user reads it:

```markdown
### <게이트 이름>
- 대상: 커널 <게이트> 검사 (file_off 0x…)
- 이유: <이 환경에서 왜 실패하는가 — 서명·엔트로피·파티션 환경 차이 등>
- 방법: <expected 0x… → new 0x…>, pre-image 확인 후 적용
- 부작용: <이제 무엇이 검증되지 않는가>
```

**The 부작용 field is read first when the run later stalls**, as the prime
suspect. Filled in carelessly, it is useless at exactly the moment it matters.

## Traps

- **Never open several gates in one round** - you lose track of which one worked.
- If the boot stops at the same place after a gate was opened, **that patch may be
  the cause** (another check often follows). Suspect the previous bypass before
  adding a new one.
- **TEE and the secure world (vold, Keymint, TEEGRIS) are the frontier.** They are
  separate from storage and rootfs, and emulating the secure world is out of scope
  for this plugin. Do not try to break through - record it honestly as
  unreached (hard blocker `BLOCKED_TEE`).
