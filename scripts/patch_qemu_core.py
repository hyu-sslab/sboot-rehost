#!/usr/bin/env python3
"""patch_qemu_core.py — faithful SMC 코어 3 패치 (QEMU 10.2.2 target/arm).
멱등. 전부 cpu->interrupt_handler != NULL 로 게이트 → virt 등 타 머신 무영향.

  1) cpu.h           : ARMCPU 에 `void (*interrupt_handler)(CPUState*)` 추가.
  2) tcg/op_helper.c : pre_smc 의 has_el3=false UDEF 2 경로를 핸들러 설정 시 우회 → SMC→EXCP_SMC.
  3) helper.c        : EXCP_SMC 를 핸들러로 라우팅 (SMC 전용; HVC 는 커널 EL2/pKVM 에 맡김).

계열별 패치 세트 (--family exynos|mediatek|all, 기본값 exynos = 위 3 패치만):
  exynos    위 1)~3). 기존 동작 그대로.
  mediatek  4) cpu.c : `aarch64=false` 거부 조건을 `!kvm_enabled() || !aarch32_supported` 에서
                       `kvm_enabled() && !aarch32_supported` 로. TCG 는 ARMv8 CPU 모델 어디서나 AArch32
                       리셋 경로를 돌릴 수 있고, 진짜 32비트 EL1 하드웨어가 필요한 쪽은 KVM 뿐이다.
                       (EL3 모니터는 진짜 BL31 이 처리하므로 SMC 훅은 필요 없다.)
  all       둘 다.

적용한 파일은 $QEMU_SRC/.sboot_touched 에 "M <상대경로>" 한 줄씩 남긴다 (경로당 한 번, 마커가 이미 있어
건너뛴 경우도 포함). scripts/qemu_tree.sh reset 이 이 장부로 원본 tarball 에서 되돌린다.

anchor 가 다른 QEMU 버전이면 count!=1 로 fail-loud (다른 버전은 anchor 재확인)."""
import sys, os, argparse
Q = os.environ.get("QEMU_SRC", os.path.expanduser("~/qemu-build/qemu-10.2.2"))
CPUH, OPH, HLP = Q+"/target/arm/cpu.h", Q+"/target/arm/tcg/op_helper.c", Q+"/target/arm/helper.c"
CPUC = Q+"/target/arm/cpu.c"
MANIFEST = Q+"/.sboot_touched"

_ap = argparse.ArgumentParser(description="QEMU 10.2.2 target/arm 코어 패치 (계열별 세트, 멱등)")
_ap.add_argument("--family", choices=("exynos", "mediatek", "all"), default="exynos",
                 help="패치 세트. 기본값 exynos = SMC 훅 3패치 (기존 동작)")
FAMILY = _ap.parse_args().family

def record_touched(path):
    """우리가 손댄 기존 QEMU 파일을 장부에 한 번만 적는다 (qemu_tree.sh reset 이 이 목록을 되돌린다)."""
    line = "M " + os.path.relpath(path, Q).replace(os.sep, "/")
    try:
        have = open(MANIFEST).read()
    except FileNotFoundError:
        have = ""
    if line in have.splitlines(): return
    with open(MANIFEST, "a") as f:
        if have and not have.endswith("\n"): f.write("\n")
        f.write(line + "\n")

def patch(path, old, new, marker, tag, family="exynos"):
    if FAMILY not in (family, "all"): return
    if not os.path.isfile(path):
        print("  [FAIL] %s: 파일 없음 %s -- ABORT" % (tag, path)); sys.exit(1)
    s = open(path).read()
    if marker in s: print("  [skip]", tag); record_touched(path); return
    if s.count(old) != 1:
        print("  [FAIL] %s: anchor count=%d (expected 1) -- ABORT" % (tag, s.count(old))); sys.exit(1)
    open(path, "w").write(s.replace(old, new, 1)); record_touched(path); print("  [ok]  ", tag)

patch(CPUH,
    "    uint32_t psci_conduit;\n",
    "    uint32_t psci_conduit;\n\n    /* Board SMC interception (faithful EL3 firmware shim). */\n"
    "    void (*interrupt_handler)(CPUState *cs);\n",
    "interrupt_handler", "cpu.h: ARMCPU.interrupt_handler")

patch(OPH,
    "    if (!arm_feature(env, ARM_FEATURE_EL3) &&\n"
    "        !(arm_hcr_el2_eff(env) & HCR_NV) &&\n"
    "        cpu->psci_conduit != QEMU_PSCI_CONDUIT_SMC) {",
    "    if (!cpu->interrupt_handler &&\n"
    "        !arm_feature(env, ARM_FEATURE_EL3) &&\n"
    "        !(arm_hcr_el2_eff(env) & HCR_NV) &&\n"
    "        cpu->psci_conduit != QEMU_PSCI_CONDUIT_SMC) {",
    "if (!cpu->interrupt_handler &&\n        !arm_feature(env, ARM_FEATURE_EL3) &&\n        !(arm_hcr_el2_eff",
    "pre_smc: skip 1st UDEF")

patch(OPH,
    "    if (!arm_is_psci_call(cpu, EXCP_SMC) &&\n"
    "        (smd || !arm_feature(env, ARM_FEATURE_EL3))) {",
    "    if (!cpu->interrupt_handler &&\n"
    "        !arm_is_psci_call(cpu, EXCP_SMC) &&\n"
    "        (smd || !arm_feature(env, ARM_FEATURE_EL3))) {",
    "if (!cpu->interrupt_handler &&\n        !arm_is_psci_call(cpu, EXCP_SMC) &&",
    "pre_smc: skip 2nd UDEF")

patch(HLP,
    "    if (tcg_enabled() && arm_is_psci_call(cpu, cs->exception_index)) {\n"
    "        arm_handle_psci_call(cpu);",
    "    if (cpu->interrupt_handler &&\n        cs->exception_index == EXCP_SMC) {\n"
    "        cpu->interrupt_handler(cs);\n        return;\n    }\n\n"
    "    if (tcg_enabled() && arm_is_psci_call(cpu, cs->exception_index)) {\n"
    "        arm_handle_psci_call(cpu);",
    "cpu->interrupt_handler &&\n        cs->exception_index == EXCP_SMC) {",
    "helper.c: route EXCP_SMC (SMC-only)")

if FAMILY in ("exynos", "all"):
    print("QEMU 10.2.2 core: faithful SMC interception in place (idempotent).")

# 4) mediatek: TCG may create an AArch32 CPU (aarch64=false); the restriction stays for KVM.
patch(CPUC,
    "        if (!kvm_enabled() || !kvm_arm_aarch32_supported()) {\n"
    "            error_setg(errp, \"'aarch64' feature cannot be disabled \"\n"
    "                             \"unless KVM is enabled and 32-bit EL1 \"\n"
    "                             \"is supported\");\n"
    "            return;\n"
    "        }\n",
    "        /* sboot-rehost: TCG can run an AArch32 reset on any ARMv8 CPU model, so the\n"
    "         * restriction applies to KVM only (it needs real 32-bit EL1 hardware). */\n"
    "        if (kvm_enabled() && !kvm_arm_aarch32_supported()) {\n"
    "            error_setg(errp, \"'aarch64' feature cannot be disabled \"\n"
    "                             \"on this KVM host (32-bit EL1 not supported)\");\n"
    "            return;\n"
    "        }\n",
    "sboot-rehost: TCG can run an AArch32 reset", "cpu.c: aarch64=false allowed under TCG",
    family="mediatek")
if FAMILY in ("mediatek", "all"):
    print("QEMU 10.2.2 core: AArch32 CPU (aarch64=false) allowed under TCG (idempotent).")
