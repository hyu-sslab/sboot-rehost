#!/usr/bin/env bash
# tests/parts/machine_tmpl.sh - 머신 영역: 템플릿 두 개, QEMU 코어 패치(계열별), 참조 예제.
#
#   bash tests/parts/machine_tmpl.sh
#
# 합성 입력만 쓴다 (임시 폴더, 끝에 지운다). 환경변수로 실제 QEMU 를 가리키면 그것도 시험한다:
#   SBOOT_TEST_QEMU_SRC   pristine QEMU 10.2.2 소스 (target/arm/{cpu.c,cpu.h,helper.c,tcg/op_helper.c} 만 있어도 된다)
#                         -> 실제 anchor 에 세 계열 패치를 적용해 본다
#   SBOOT_TEST_QEMU_TREE  configure 된 QEMU 10.2.2 소스 트리 (build/ 포함) -> 채운 템플릿 두 개를 실제 헤더로 컴파일해 본다
#                         (hw/arm/meson.build 를 잠시 고치고 끝에 되돌린다)
. "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

hdr "머신: 코어 패치 계열 · 템플릿 · 참조 예제"

MT_DIR="$ROOT/machine_tmpl"; rm -rf "$MT_DIR"; mkdir -p "$MT_DIR"
MT_PQ="$S/patch_qemu_core.py"
MT_T_FULL="$REPO/templates/machine_full.c.tmpl"
MT_T_MIX="$REPO/templates/machine_mixed_arch.c.tmpl"
MT_EX="$REPO/examples/a136u-mt6833"

# ---------------------------------------------------------------------------
# 합성 QEMU 트리 — 패치 anchor 가 되는 줄만 담는다 (QEMU 10.2.2 의 같은 줄)
# ---------------------------------------------------------------------------
mt_qtree() {   # $1 = dir
    local d="$1"; mkdir -p "$d/target/arm/tcg"
    cat > "$d/target/arm/cpu.h" <<'EOF'
struct ArchCPU {
    /* PSCI conduit used to handle HVC and SMC instructions */
    uint32_t psci_conduit;

    /* For v8M, initial value of the Secure VTOR */
    uint32_t init_svtor;
};
EOF
    cat > "$d/target/arm/tcg/op_helper.c" <<'EOF'
void HELPER(pre_smc)(CPUARMState *env, uint32_t syndrome)
{
    ARMCPU *cpu = env_archcpu(env);
    if (!arm_feature(env, ARM_FEATURE_EL3) &&
        !(arm_hcr_el2_eff(env) & HCR_NV) &&
        cpu->psci_conduit != QEMU_PSCI_CONDUIT_SMC) {
        raise_exception(env, EXCP_UDEF, syn_uncategorized(), exception_target_el(env));
    }
    if (!arm_is_psci_call(cpu, EXCP_SMC) &&
        (smd || !arm_feature(env, ARM_FEATURE_EL3))) {
        raise_exception(env, EXCP_UDEF, syn_uncategorized(), exception_target_el(env));
    }
}
EOF
    cat > "$d/target/arm/helper.c" <<'EOF'
void arm_cpu_do_interrupt(CPUState *cs)
{
    if (tcg_enabled() && arm_is_psci_call(cpu, cs->exception_index)) {
        arm_handle_psci_call(cpu);
        return;
    }
}
EOF
    cat > "$d/target/arm/cpu.c" <<'EOF'
static void arm_set_aarch64(Object *obj, bool value, Error **errp)
{
    /*
     * At this time, this property is only allowed if KVM is enabled.  This
     * restriction allows us to avoid fixing up functionality that assumes a
     * uniform execution state like do_interrupt.
     */
    if (value == false) {
        if (!kvm_enabled() || !kvm_arm_aarch32_supported()) {
            error_setg(errp, "'aarch64' feature cannot be disabled "
                             "unless KVM is enabled and 32-bit EL1 "
                             "is supported");
            return;
        }
        unset_feature(&cpu->env, ARM_FEATURE_AARCH64);
    } else {
        set_feature(&cpu->env, ARM_FEATURE_AARCH64);
    }
}
EOF
}

mt_pq() {   # $1 = tree, 나머지 = 인자.  stdout 은 MT_PQ_OUT, 종료코드는 MT_PQ_RC
    local t="$1"; shift
    MT_PQ_OUT=$(QEMU_SRC="$t" python3 "$MT_PQ" "$@" 2>&1); MT_PQ_RC=$?
}
mt_cnt() { printf '%s\n' "$1" | grep -c -- "$2"; }   # 일치하는 줄 수 (없으면 0)
mt_manifest() { [ -f "$1/.sboot_touched" ] && wc -l < "$1/.sboot_touched" | tr -d ' ' || echo none; }

MT_EXPECT_DEFAULT_OUT='  [ok]   cpu.h: ARMCPU.interrupt_handler
  [ok]   pre_smc: skip 1st UDEF
  [ok]   pre_smc: skip 2nd UDEF
  [ok]   helper.c: route EXCP_SMC (SMC-only)
QEMU 10.2.2 core: faithful SMC interception in place (idempotent).'

# ---- 1. 기본 호출: 기존 동작 그대로 (SMC 훅 3패치, cpu.c 는 손대지 않는다) ----
MT_QD="$MT_DIR/q_default"; mt_qtree "$MT_QD"; cp "$MT_QD/target/arm/cpu.c" "$MT_DIR/cpu.c.orig"
mt_pq "$MT_QD"
chk "기본 호출: 종료코드 0"                      "$MT_PQ_RC" "0"
chk "기본 호출: 출력이 기존과 같다"                "$MT_PQ_OUT" "$MT_EXPECT_DEFAULT_OUT"
chk "기본 호출: cpu.c 는 그대로"                  "$(cmp -s "$MT_QD/target/arm/cpu.c" "$MT_DIR/cpu.c.orig" && echo same || echo changed)" "same"
chk "기본 호출: cpu.h 에 interrupt_handler"       "$(grep -c 'void (\*interrupt_handler)(CPUState \*cs);' "$MT_QD/target/arm/cpu.h")" "1"
chk "기본 호출: 매니페스트 3경로 (op_helper 는 한 번)" "$(mt_manifest "$MT_QD")" "3"
chk "기본 호출: 매니페스트에 cpu.h"               "$(grep -cx 'M target/arm/cpu.h' "$MT_QD/.sboot_touched")" "1"
chk "기본 호출: 매니페스트에 op_helper.c"         "$(grep -cx 'M target/arm/tcg/op_helper.c' "$MT_QD/.sboot_touched")" "1"
chk "기본 호출: 매니페스트에 helper.c"            "$(grep -cx 'M target/arm/helper.c' "$MT_QD/.sboot_touched")" "1"
chk "기본 호출: cpu.c 는 매니페스트에 없다"        "$(grep -c 'cpu.c' "$MT_QD/.sboot_touched")" "0"
mt_pq "$MT_QD"
chk "기본 호출 두 번째: 전부 skip"                "$(mt_cnt "$MT_PQ_OUT" '\[skip\]')" "4"
chk "기본 호출 두 번째: 매니페스트 그대로 3줄"      "$(mt_manifest "$MT_QD")" "3"

# ---- 2. --family exynos 는 기본 호출과 같다 ----
MT_QE="$MT_DIR/q_exynos"; mt_qtree "$MT_QE"
mt_pq "$MT_QE" --family exynos
chk "exynos: 기본 호출과 출력 동일"                "$MT_PQ_OUT" "$MT_EXPECT_DEFAULT_OUT"
chk "exynos: 기본 호출과 트리 동일"                "$(diff -r "$MT_QD" "$MT_QE" >/dev/null 2>&1 && echo same || echo differ)" "same"

# ---- 3. --family mediatek: cpu.c 한 건, SMC 훅 없음 ----
MT_QM="$MT_DIR/q_mt"; mt_qtree "$MT_QM"; cp -R "$MT_QM" "$MT_DIR/q_mt_before"
mt_pq "$MT_QM" --family mediatek
chk "mediatek: 종료코드 0"                        "$MT_PQ_RC" "0"
chk "mediatek: 패치 한 건 [ok]"                   "$(mt_cnt "$MT_PQ_OUT" '\[ok\]')" "1"
chk "mediatek: 옛 조건이 없어졌다"                 "$(grep -c '!kvm_enabled() || !kvm_arm_aarch32_supported()' "$MT_QM/target/arm/cpu.c")" "0"
chk "mediatek: KVM 에만 제한을 건다"               "$(grep -c 'if (kvm_enabled() && !kvm_arm_aarch32_supported()) {' "$MT_QM/target/arm/cpu.c")" "1"
chk "mediatek: 오류 문구는 KVM 호스트 한정"         "$(grep -c "on this KVM host (32-bit EL1 not supported)" "$MT_QM/target/arm/cpu.c")" "1"
chk "mediatek: unset_feature 는 그대로"           "$(grep -c 'unset_feature(&cpu->env, ARM_FEATURE_AARCH64);' "$MT_QM/target/arm/cpu.c")" "1"
chk "mediatek: SMC 훅 세 파일은 손대지 않았다"       "$(for f in cpu.h helper.c tcg/op_helper.c; do cmp -s "$MT_QM/target/arm/$f" "$MT_DIR/q_mt_before/target/arm/$f" && echo s; done | wc -l | tr -d ' ')" "3"
chk "mediatek: 매니페스트는 cpu.c 한 줄"           "$(cat "$MT_QM/.sboot_touched")" "M target/arm/cpu.c"
mt_pq "$MT_QM" --family mediatek
chk "mediatek 두 번째: skip"                      "$(mt_cnt "$MT_PQ_OUT" '\[skip\]')" "1"
chk "mediatek 두 번째: 매니페스트 그대로"           "$(mt_manifest "$MT_QM")" "1"

# ---- 4. --family all: 둘 다, 각 경로는 매니페스트에 한 번 ----
MT_QA="$MT_DIR/q_all"; mt_qtree "$MT_QA"
mt_pq "$MT_QA" --family all
chk "all: 종료코드 0"                             "$MT_PQ_RC" "0"
chk "all: 패치 5건 [ok]"                          "$(mt_cnt "$MT_PQ_OUT" '\[ok\]')" "5"
chk "all: 매니페스트 4경로"                        "$(mt_manifest "$MT_QA")" "4"
chk "all: 매니페스트에 중복 없음"                   "$(sort "$MT_QA/.sboot_touched" | uniq -d | wc -l | tr -d ' ')" "0"
mt_pq "$MT_QA" --family all
chk "all 두 번째: 5건 전부 skip"                   "$(mt_cnt "$MT_PQ_OUT" '\[skip\]')" "5"
MT_QM2="$MT_DIR/q_mt_then_ex"; mt_qtree "$MT_QM2"
QEMU_SRC="$MT_QM2" python3 "$MT_PQ" --family mediatek >/dev/null 2>&1; QEMU_SRC="$MT_QM2" python3 "$MT_PQ" >/dev/null 2>&1
chk "all = mediatek 과 exynos 를 차례로 적용한 것과 같은 트리"  "$(diff -r "$MT_QA/target" "$MT_QM2/target" >/dev/null 2>&1 && echo same || echo differ)" "same"

# ---- 5. 매니페스트가 없던 옛 트리: 마커가 있어 skip 해도 경로를 기록한다 (reset 이 되돌릴 수 있게) ----
rm -f "$MT_QA/.sboot_touched"
mt_pq "$MT_QA" --family all
chk "매니페스트 없는 패치 완료 트리: skip 이어도 4경로 기록"  "$(mt_manifest "$MT_QA")" "4"

# ---- 6. fail-loud: anchor 가 정확히 1개가 아니면 쓰지 않고 멈춘다 ----
MT_QF="$MT_DIR/q_fail0"; mt_qtree "$MT_QF"
sed 's/kvm_arm_aarch32_supported/kvm_arm_aarch32_supported_x/' "$MT_QF/target/arm/cpu.c" > "$MT_QF/cpu.c.new" && mv "$MT_QF/cpu.c.new" "$MT_QF/target/arm/cpu.c"
cp "$MT_QF/target/arm/cpu.c" "$MT_DIR/cpu.c.fail0"
mt_pq "$MT_QF" --family mediatek
chk "anchor 0개: 종료코드 1"                      "$MT_PQ_RC" "1"
chk "anchor 0개: FAIL 과 count=0 를 말한다"        "$(mt_cnt "$MT_PQ_OUT" '\[FAIL\].*count=0')" "1"
chk "anchor 0개: 파일을 쓰지 않았다"                "$(cmp -s "$MT_QF/target/arm/cpu.c" "$MT_DIR/cpu.c.fail0" && echo same || echo changed)" "same"
chk "anchor 0개: 매니페스트를 만들지 않았다"         "$(mt_manifest "$MT_QF")" "none"
MT_QG="$MT_DIR/q_fail2"; mt_qtree "$MT_QG"
# 같은 블록이 두 번 있으면 어느 쪽인지 모르므로 거부한다
{ cat "$MT_QG/target/arm/cpu.c"; cat "$MT_QG/target/arm/cpu.c"; } > "$MT_QG/cpu.c.new" && mv "$MT_QG/cpu.c.new" "$MT_QG/target/arm/cpu.c"
mt_pq "$MT_QG" --family mediatek
chk "anchor 2개: 종료코드 1 과 count=2"            "$MT_PQ_RC/$(mt_cnt "$MT_PQ_OUT" '\[FAIL\].*count=2')" "1/1"
MT_QH="$MT_DIR/q_fail_exynos"; mt_qtree "$MT_QH"
sed 's/uint32_t psci_conduit;/uint32_t psci_conduit_x;/' "$MT_QH/target/arm/cpu.h" > "$MT_QH/h.new" && mv "$MT_QH/h.new" "$MT_QH/target/arm/cpu.h"
mt_pq "$MT_QH"
chk "기본 호출도 anchor 가 없으면 종료코드 1"        "$MT_PQ_RC/$(mt_cnt "$MT_PQ_OUT" '\[FAIL\].*count=0')" "1/1"
MT_QI="$MT_DIR/q_nofile"; mkdir -p "$MT_QI"
mt_pq "$MT_QI" --family mediatek
chk "파일이 없으면 종료코드 1 (트레이스백 아님)"     "$MT_PQ_RC/$(mt_cnt "$MT_PQ_OUT" 'Traceback')" "1/0"
mt_pq "$MT_QM" --family arm32
chk "알 수 없는 계열은 거부 (종료코드 2)"            "$MT_PQ_RC" "2"

# ---- 6b. 장부 호환: qemu_tree.sh reset 이 패치한 트리를 pristine tarball 로 되돌린다 (C5) ----
if [ -f "$S/qemu_tree.sh" ] && command -v tar >/dev/null 2>&1; then
    MT_RT="$MT_DIR/rt"; mkdir -p "$MT_RT/qemu-10.2.2"; mt_qtree "$MT_RT/qemu-10.2.2"
    ( cd "$MT_RT" && tar cJf qemu-10.2.2.tar.xz qemu-10.2.2 ) >/dev/null 2>&1
    if [ -f "$MT_RT/qemu-10.2.2.tar.xz" ]; then
        cp -R "$MT_RT/qemu-10.2.2/target" "$MT_RT/pristine_target"
        QEMU_SRC="$MT_RT/qemu-10.2.2" python3 "$MT_PQ" --family all >/dev/null 2>&1
        MT_RESET=$(QEMU_SRC="$MT_RT/qemu-10.2.2" bash "$S/qemu_tree.sh" reset 2>/dev/null)
        chk "qemu_tree.sh reset: 패치한 트리가 pristine 으로 돌아온다"   "$(diff -r "$MT_RT/pristine_target" "$MT_RT/qemu-10.2.2/target" >/dev/null 2>&1 && echo same || echo differ)" "same"
        chk "qemu_tree.sh reset: 장부가 비워진다"                        "$(wc -c < "$MT_RT/qemu-10.2.2/.sboot_touched" | tr -d ' ')" "0"
        QEMU_SRC="$MT_RT/qemu-10.2.2" python3 "$MT_PQ" --family mediatek >/dev/null 2>&1
        chk "reset 뒤 다시 패치하면 장부에 다시 적는다"                    "$(cat "$MT_RT/qemu-10.2.2/.sboot_touched")" "M target/arm/cpu.c"
    else
        printf '  \033[2mSKIP\033[0m 장부 호환 시험 (tar 가 xz 를 만들지 못함)\n'
    fi
else
    printf '  \033[2mSKIP\033[0m 장부 호환 시험 (qemu_tree.sh 없음)\n'
fi

# ---- 7. 실제 QEMU 소스가 있으면 같은 시험을 실제 anchor 로 ----
if [ -n "${SBOOT_TEST_QEMU_SRC:-}" ] && [ -f "$SBOOT_TEST_QEMU_SRC/target/arm/cpu.c" ]; then
    MT_QR="$MT_DIR/q_real"; mkdir -p "$MT_QR/target/arm/tcg"
    for f in cpu.c cpu.h helper.c tcg/op_helper.c; do cp "$SBOOT_TEST_QEMU_SRC/target/arm/$f" "$MT_QR/target/arm/$f"; done
    mt_pq "$MT_QR" --family all
    chk "실제 소스: all 은 5건 [ok]"                "$MT_PQ_RC/$(mt_cnt "$MT_PQ_OUT" '\[ok\]')" "0/5"
    mt_pq "$MT_QR" --family all
    chk "실제 소스: 두 번째는 전부 skip"             "$(mt_cnt "$MT_PQ_OUT" '\[skip\]')" "5"
else
    printf '  \033[2mSKIP\033[0m 실제 QEMU 소스 시험 (SBOOT_TEST_QEMU_SRC 미지정)\n'
fi

# ---------------------------------------------------------------------------
# 템플릿: .interfaces
# ---------------------------------------------------------------------------
mt_typeinfo() { awk '/^static const TypeInfo /{p=1} p{print} p&&/^};/{exit}' "$1"; }
chk "machine_full: TypeInfo 에 .interfaces"        "$(mt_typeinfo "$MT_T_FULL" | grep -c '^    \.interfaces = arm_aarch64_machine_interfaces,')" "1"
chk "machine_full: 인터페이스 배열 헤더를 포함"       "$(grep -c '#include "hw/arm/machines-qom.h"' "$MT_T_FULL")" "1"
chk "machine_mixed: 파일이 있다"                   "$([ -f "$MT_T_MIX" ] && echo yes || echo no)" "yes"
chk "machine_mixed: TypeInfo 에 .interfaces"       "$(mt_typeinfo "$MT_T_MIX" | grep -c '^    \.interfaces = aarch64_machine_interfaces,')" "1"
chk "machine_mixed: 인터페이스 배열 헤더를 포함"      "$(grep -c '#include "hw/arm/machines-qom.h"' "$MT_T_MIX")" "1"

# ---------------------------------------------------------------------------
# machine_mixed_arch.c.tmpl: 골격의 구성 요소
# ---------------------------------------------------------------------------
mt_has() { grep -q -- "$2" "$1" && echo yes || echo no; }
MT_LN_MON=$(grep -n 'object_new(ARM_CPU_TYPE_NAME("{{CPU64_TYPE}}"))' "$MT_T_MIX" | head -1 | cut -d: -f1)
MT_LN_BOOT=$(grep -n 'object_new(ARM_CPU_TYPE_NAME("{{CPU32_TYPE}}"))' "$MT_T_MIX" | head -1 | cut -d: -f1)
chk "mixed: EL3 모니터 CPU 를 먼저 만든다 (생성 순서)"  "$([ -n "$MT_LN_MON" ] && [ -n "$MT_LN_BOOT" ] && [ "$MT_LN_MON" -lt "$MT_LN_BOOT" ] && echo monitor-first || echo wrong)" "monitor-first"
chk "mixed: 생성 순서를 런타임에 단언"               "$(mt_has "$MT_T_MIX" 'cpu_index == i')" "yes"
chk "mixed: aarch64=false 보조 CPU (코어 패치 필요 명시)" "$(mt_has "$MT_T_MIX" 'patch_qemu_core.py --family mediatek')" "yes"
chk "mixed: GICv3"                                 "$(mt_has "$MT_T_MIX" 'qdev_new("arm-gicv3")')" "yes"
chk "mixed: 핸드오프 감시 (warm reset)"             "$(mt_has "$MT_T_MIX" 'static void handoff_tick')" "yes"
chk "mixed: 핸드오프 요청 판정이 자리표시자 기반"     "$(mt_has "$MT_T_MIX" 'HANDOFF_SPIN_PC_LO')" "yes"
chk "mixed: g_post_handoff 는 한 번만 정의"         "$(grep -c '^static bool g_post_handoff;' "$MT_T_MIX")" "1"
chk "mixed: 타이머 (가상시간 카운터·배속)"           "$(mt_has "$MT_T_MIX" 'rehost_virtual_ticks')" "yes"
chk "mixed: 예약 영역 표"                 "$(mt_has "$MT_T_MIX" 'reserved_spans')" "yes"
chk "mixed: 섀도우 첫 접근 기록 ACCESSED"           "$(mt_has "$MT_T_MIX" '"ACCESSED"')" "yes"
chk "mixed: catch-all 의 UNMODELLED"                "$(mt_has "$MT_T_MIX" '"UNMODELLED"')" "yes"
chk "mixed: 4 KiB 페이지 단위"                       "$(mt_has "$MT_T_MIX" 'define MMIO_PAGE_SHIFT  12')" "yes"
chk "mixed: 폴링 진단 임계 3000"                     "$(mt_has "$MT_T_MIX" 'define POLL_THRESHOLD   3000')" "yes"
chk "mixed: 읽기 덮어쓰기 표"                        "$(mt_has "$MT_T_MIX" 'read_overrides\[\]')" "yes"
chk "mixed: 레지스터 훅 표 (콜백 밖 특례)"            "$(mt_has "$MT_T_MIX" 'reg_hooks\[\]')" "yes"
chk "mixed: 전용 모델 등록 함수"                      "$(mt_has "$MT_T_MIX" 'rehost_add_dedicated')" "yes"
chk "mixed: 매체 모델 연결점"                         "$(mt_has "$MT_T_MIX" 'rehost_medium_connect')" "yes"
chk "mixed: 런타임 패치: 대상 빌드 식별"               "$(mt_has "$MT_T_MIX" 'patch_target_confirmed')" "yes"
chk "mixed: 런타임 패치: 그룹 원자성"                  "$(mt_has "$MT_T_MIX" 'patch_group_ready')" "yes"
chk "mixed: 런타임 패치: 적용하지 않고 기록"            "$(mt_has "$MT_T_MIX" 'PATCH-REFUSED')" "yes"
chk "mixed: 패치 행 태그 형식 bypass:<id>"             "$(mt_has "$MT_T_MIX" 'bypass:<id> \*/')" "yes"
chk "mixed: 진단 환경변수 3개"                         "$(for v in REHOST_HEARTBEAT REHOST_TIME_SCALE REHOST_RUNTIME_PATCHES; do grep -c "$v" "$MT_T_MIX" | grep -vx 0; done | wc -l | tr -d ' ')" "3"
chk "mixed: memdump 영역에 쓰지 않는 단일 쓰기 경로"    "$(mt_has "$MT_T_MIX" 'static bool rehost_guest_write')" "yes"
chk "mixed: UART 출력 호출은 정확히 한 곳"             "$(grep -v '^ *\*\|^ */\*' "$MT_T_MIX" | grep -c 'qemu_chr_fe_write_all(')" "1"
chk "mixed: 직접 RX 주입 호출이 없다"                  "$(grep -c 'qemu_chr_be_write\|rx_seed' "$MT_T_MIX")" "0"
chk "mixed: accept_input 호출 있음"                    "$(mt_has "$MT_T_MIX" 'qemu_chr_fe_accept_input')" "yes"

# ---------------------------------------------------------------------------
# machine_mixed_arch.c.tmpl: 칩 상수가 없다
# ---------------------------------------------------------------------------
# 허용 목록 — 구조적이거나 아키텍처 상수이지 칩 값이 아닌 것만:
#   0x0 0x1 0x2 0xf 0xff 0xfff  자리·마스크·비트 수준의 작은 값 (0xff 는 UART TX 한 바이트 마스크)
#   0xEAFFFFFE                  A32 명령 "b ." 의 아키텍처 인코딩
MT_ALLOW_HEX="0x0 0x1 0x2 0xf 0xff 0xfff 0xeafffffe"
# 허용하는 큰 십진수 — FNV-1a 32 비트의 오프셋 기준값과 소수 (칩 값이 아니라 해시 알고리즘의 정의)
MT_ALLOW_DEC="2166136261 16777619"
MT_FOUND_HEX=$(grep -oiE '0x[0-9a-f]+' "$MT_T_MIX" | tr 'A-F' 'a-f' | sort -u)
MT_BAD_HEX=""; for mt_h in $MT_FOUND_HEX; do case " $MT_ALLOW_HEX " in *" $mt_h "*) ;; *) MT_BAD_HEX="$MT_BAD_HEX $mt_h";; esac; done
chk "mixed: 허용 목록 밖의 16진 상수가 없다"            "${MT_BAD_HEX:-none}" "none"
MT_FOUND_DEC=$(grep -oE '\b[0-9]{5,}[uUlL]*\b' "$MT_T_MIX" | tr -d 'uUlL' | sort -u)
MT_BAD_DEC=""; for mt_d in $MT_FOUND_DEC; do case " $MT_ALLOW_DEC " in *" $mt_d "*) ;; *) MT_BAD_DEC="$MT_BAD_DEC $mt_d";; esac; done
chk "mixed: 허용 목록 밖의 다섯 자리 이상 십진 상수가 없다"  "${MT_BAD_DEC:-none}" "none"
chk "mixed: 벤더·기기 문자열이 없다"                     "$(grep -v -- '--family mediatek' "$MT_T_MIX" | grep -ciE 'mediatek|mtk|mt[0-9]{4}|samsung|exynos|a136|qualcomm|snapdragon|kirin|unisoc|spreadtrum|cortex|preloader|bl31|teegris|[^a-z]lk[^a-z]')" "0"
chk "mixed: 자리표시자는 대문자 이름뿐"                   "$(grep -o '{{[^}]*}}' "$MT_T_MIX" | grep -vcE '^\{\{[A-Z0-9_]+\}\}$')" "0"
chk "mixed: 주소·값 자리표시자가 충분히 있다 (20개 이상)"  "$([ "$(grep -o '{{[A-Z0-9_]*}}' "$MT_T_MIX" | sort -u | wc -l | tr -d ' ')" -ge 20 ] && echo yes || echo no)" "yes"

# ---------------------------------------------------------------------------
# 런타임 패치 엔진 · memdump 쓰기 차단 — 템플릿에서 해당 구간만 떼어 호스트 cc 로 실제 실행
# ---------------------------------------------------------------------------
if command -v cc >/dev/null 2>&1; then
    MT_EN="$MT_DIR/engine"; mkdir -p "$MT_EN"
    sed -n '/^\/\* begin: guest memory access \*\//,/^\/\* end: guest memory access \*\//p' "$MT_T_MIX" > "$MT_EN/guestmem.inc"
    sed -n '/^\/\* begin: patch engine \*\//,/^\/\* end: patch engine \*\//p' "$MT_T_MIX" > "$MT_EN/engine.inc"
    MT_PML=$(grep -m1 '^#define PATCH_MAX_LEN' "$MT_T_MIX"); MT_PID=$(grep -m1 '^#define PATCH_ID_MAX' "$MT_T_MIX"); MT_PPM=$(grep -m1 '^#define PATCH_POLL_MS' "$MT_T_MIX")
    MT_HASH_A=$(python3 -c 'import sys
h=2166136261
for b in b"BUILD-A": h=((h^b)*16777619)&0xffffffff
print(h)')
    MT_HASH_X=$(python3 -c 'import sys
h=2166136261
for b in b"BUILD-X": h=((h^b)*16777619)&0xffffffff
print(h)')
    # 시험용 행을 템플릿의 표 자리에 끼워 넣는다 (자리표시자 주석 바로 앞)
    python3 - "$MT_EN/engine.inc" "$MT_HASH_A" "$MT_HASH_X" <<'PY'
import sys
p, ha, hx = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(p).read()
tg = ('    { "A", 0x100, 7, %su, "after the first stage" },\n'
      '    { "B", 0x200, 7, %su, "kernel" },\n' % (ha, hx))
rows = '''    { .id = "g1a", .group = 1, .target = 0, .when = PATCH_AT_RUNTIME, .addr = 0x300, .len = 2, .from = {1,2}, .to = {9,9} },
    { .id = "g1b", .group = 1, .target = 0, .when = PATCH_AT_RUNTIME, .addr = 0x310, .len = 2, .from = {3,4}, .to = {8,8} },
    { .id = "g2a", .group = 2, .target = 0, .when = PATCH_AT_RUNTIME, .addr = 0x320, .len = 2, .from = {5,6}, .to = {7,7} },
    { .id = "g2b", .group = 2, .target = 0, .when = PATCH_AT_RUNTIME, .addr = 0x330, .len = 2, .from = {1,1}, .to = {2,2} },
    { .id = "g3a", .group = 3, .target = 1, .when = PATCH_AT_RUNTIME, .addr = 0x340, .len = 2, .from = {5,5}, .to = {6,6} },
    { .id = "g4a", .group = 4, .target = 0, .when = PATCH_AT_LOAD,    .addr = 0x350, .len = 2, .from = {1,1}, .to = {2,2} },
    { .id = "g5a", .group = 5, .target = 0, .when = PATCH_AT_LOAD,    .addr = 0x360, .len = 2, .from = {4,4}, .to = {5,5} },
'''
a = '    /* {{PATCH_TARGETS_BLOCK}}'
b = '    /* {{PATCH_ROWS_BLOCK}}'
assert s.count(a) == 1 and s.count(b) == 1
s = s.replace(a, tg + a).replace(b, rows + b)
open(p, 'w').write(s)
PY
    cat > "$MT_EN/harness.c" <<EOF
#include <stdio.h>
#include <stdint.h>
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>
#include <stdarg.h>
#include <inttypes.h>
#include <errno.h>
#define G_GNUC_UNUSED __attribute__((unused))
#define g_new0(t, n) ((t *)calloc((n), sizeof(t)))
#define HOST_LOG(fmt, ...) printf("LOG " fmt "\n", ##__VA_ARGS__)
typedef struct Notifier Notifier;
struct Notifier { void (*notify)(Notifier *, void *); };
static void qemu_add_exit_notifier(Notifier *n) { (void)n; }
static void error_report(const char *fmt, ...) { va_list ap; va_start(ap, fmt); printf("ERR "); vprintf(fmt, ap); printf("\n"); va_end(ap); }
typedef int MemTxResult;
#define MEMTX_OK 0
#define MEMTXATTRS_UNSPECIFIED 0
typedef struct AddressSpace { int unused; } AddressSpace;
static AddressSpace address_space_memory;
static uint8_t gmem[0x10000];
static MemTxResult address_space_read(AddressSpace *as, uint64_t a, int attrs, void *buf, size_t n) { (void)as; (void)attrs; if (a + n > sizeof(gmem)) return 1; memcpy(buf, gmem + a, n); return 0; }
static MemTxResult address_space_write(AddressSpace *as, uint64_t a, int attrs, const void *buf, size_t n) { (void)as; (void)attrs; if (a + n > sizeof(gmem)) return 1; memcpy(gmem + a, buf, n); return 0; }
$MT_PML
$MT_PID
$MT_PPM
static bool g_patches_enabled = true;
typedef struct RehostMixedState { void *patch_timer; } RehostMixedState;
#define QEMU_CLOCK_VIRTUAL 0
static int64_t qemu_clock_get_ms(int c) { (void)c; return 0; }
static void timer_mod(void *t, int64_t ms) { (void)t; (void)ms; }
#include "guestmem.inc"
#include "engine.inc"
static void dump(const char *tag) {
    for (unsigned i = 0; i < patch_n_rows; i++) printf("%s STATE %s %d\n", tag, patch_rows[i].id, (int)patch_state[i]);
    static const unsigned at[] = { 0x300, 0x310, 0x320, 0x330, 0x340, 0x350, 0x360 };
    for (unsigned i = 0; i < sizeof(at) / sizeof(at[0]); i++) printf("%s MEM %x %02x%02x\n", tag, at[i], gmem[at[i]], gmem[at[i] + 1]);
}
int main(int argc, char **argv) {
    /* "parse <spec>": the REHOST_MEMDUMP_REGION parser alone.  "guard": init from the
     * environment as the machine does, then try one write into the region. */
    if (argc > 2 && !strcmp(argv[1], "parse")) {
        uint64_t b = 0, n = 0;
        if (memdump_region_parse(argv[2], &b, &n)) printf("PARSE ok %" PRIx64 " %" PRIx64 "\n", b, n);
        else printf("PARSE bad\n");
        return 0;
    }
    if (argc > 1 && !strcmp(argv[1], "guard")) {
        uint8_t g[4] = { 1, 1, 1, 1 };
        memdump_guard_init();
        printf("GUARD %" PRIx64 " %" PRIx64 "\n", g_memdump_base, g_memdump_size);
        printf("GUARD_WRITE %d\n", rehost_guest_write(0x8000, g, 4));
        return 0;
    }
    setenv("REHOST_MEMDUMP_REGION", "0x8000:0x1000", 1);
    memdump_guard_init();
    memcpy(gmem + 0x100, "BUILD-A", 7);
    memcpy(gmem + 0x200, "BUILD-B", 7);
    memcpy(gmem + 0x300, "\x01\x02", 2); memcpy(gmem + 0x310, "\x03\x04", 2);
    memcpy(gmem + 0x320, "\x05\x06", 2); /* 0x330 stays 00 00: g2b pre-image mismatch */
    memcpy(gmem + 0x340, "\x05\x05", 2); /* g3a: pre-image fine, target build is not the derived one */
    /* 0x350 stays 00 00: g4a (load time) pre-image mismatch */
    memcpy(gmem + 0x360, "\x04\x04", 2);
    patch_engine_init();
    patch_try(PATCH_AT_LOAD);
    patch_try(PATCH_AT_RUNTIME);
    dump("S1");
    patch_ledger_report(NULL, NULL);
    gmem[0x330] = 1; gmem[0x331] = 1;      /* the pre-image of g2b shows up later */
    patch_try(PATCH_AT_RUNTIME);
    dump("S2");
    uint8_t w[4] = { 0xaa, 0xaa, 0xaa, 0xaa };
    printf("WRITE_MEMDUMP %d\n", rehost_guest_write(0x8000, w, 4));
    printf("WRITE_OVERLAP %d\n", rehost_guest_write(0x7ffe, w, 4));
    printf("WRITE_OUTSIDE %d\n", rehost_guest_write(0x9000, w, 4));
    printf("MEMDUMP_UNTOUCHED %d\n", gmem[0x8000] == 0 && gmem[0x7ffe] == 0);
    return 0;
}
EOF
    if cc -std=gnu11 -Wall -o "$MT_EN/harness" "$MT_EN/harness.c" 2>"$MT_EN/cc.err"; then
        ok "엔진 구간이 호스트 cc 로 컴파일된다"
        MT_EOUT=$("$MT_EN/harness" 2>&1)
        mt_st() { printf '%s\n' "$MT_EOUT" | grep "^$1 STATE $2 " | awk '{print $4}'; }
        mt_mem() { printf '%s\n' "$MT_EOUT" | grep "^$1 MEM $2 " | awk '{print $4}'; }
        # 상태: 0 대기, 1 적용, 2 거부
        chk "엔진: 같은 그룹 두 행이 모두 맞으면 둘 다 적용"          "$(mt_st S1 g1a)/$(mt_st S1 g1b)/$(mt_mem S1 300)/$(mt_mem S1 310)" "1/1/0909/0808"
        chk "엔진: 한 행이 어긋나면 그룹 전체가 적용되지 않는다 (원자성)" "$(mt_st S1 g2a)/$(mt_st S1 g2b)/$(mt_mem S1 320)/$(mt_mem S1 330)" "0/0/0506/0000"
        chk "엔진: 대상 빌드가 다르면 선검사가 맞아도 적용하지 않는다"    "$(mt_st S1 g3a)/$(mt_mem S1 340)" "0/0505"
        chk "엔진: 적재 시점 선검사 불일치는 거부로 기록"                "$(mt_st S1 g4a)/$(mt_mem S1 350)" "2/0000"
        chk "엔진: 적재 시점 일치는 적용"                              "$(mt_st S1 g5a)/$(mt_mem S1 360)" "1/0505"
        chk "엔진: 거부 줄에 PATCH-REFUSED 와 사유"                    "$(printf '%s\n' "$MT_EOUT" | grep -c 'LOG PATCH-REFUSED g4a group=4: pre-image mismatch at 0x350')" "1"
        chk "엔진: 적용 줄을 적용 시점에 남긴다 (대상과 적용 시점 포함)"   "$(printf '%s\n' "$MT_EOUT" | grep -c 'LOG patch applied  g1a group=1 @0x300 target=A when="after the first stage"')" "1"
        chk "엔진: 보고에 어긋난 행과 주소를 적는다 (그룹의 두 행 모두 같은 사유)"  "$(printf '%s\n' "$MT_EOUT" | grep -c "g2[ab] group=2 NOT applied: pre-image mismatch at 0x330 (row g2b)")" "2"
        chk "엔진: 보고에 대상 빌드 불일치와 해시를 적는다"               "$(printf '%s\n' "$MT_EOUT" | grep -c "g3a group=3 NOT applied: target 'B' build not confirmed")" "1"
        chk "엔진: 나중에 선검사가 맞으면 그 그룹이 통째로 적용"           "$(mt_st S2 g2a)/$(mt_st S2 g2b)/$(mt_mem S2 320)/$(mt_mem S2 330)" "1/1/0707/0202"
        chk "엔진: 대상 불일치 그룹은 계속 대기"                       "$(mt_st S2 g3a)/$(mt_mem S2 340)" "0/0505"
        chk "쓰기 경로: memdump 영역 쓰기는 거부"                      "$(printf '%s\n' "$MT_EOUT" | grep '^WRITE_MEMDUMP' | awk '{print $2}')" "0"
        chk "쓰기 경로: memdump 영역에 걸치는 쓰기도 거부"               "$(printf '%s\n' "$MT_EOUT" | grep '^WRITE_OVERLAP' | awk '{print $2}')" "0"
        chk "쓰기 경로: 영역 밖 쓰기는 통과"                          "$(printf '%s\n' "$MT_EOUT" | grep '^WRITE_OUTSIDE' | awk '{print $2}')" "1"
        chk "쓰기 경로: 거부된 쓰기가 메모리를 바꾸지 않았다"            "$(printf '%s\n' "$MT_EOUT" | grep '^MEMDUMP_UNTOUCHED' | awk '{print $2}')" "1"
        # 영역은 컴파일 상수가 아니라 실행 시점의 REHOST_MEMDUMP_REGION=<base>:<size> 로 온다
        # (게이트 1 이 보호 영역 안의 정수 상수를 참조로 보기 때문). 형식이 어긋나면 머신이 멈춘다.
        mt_parse() { "$MT_EN/harness" parse "$1" 2>&1; }
        chk "영역 지정: 16진 <base>:<size>"                          "$(mt_parse '0x8000:0x1000')" "PARSE ok 8000 1000"
        chk "영역 지정: 십진도 같은 뜻"                                "$(mt_parse '32768:4096')" "PARSE ok 8000 1000"
        MT_BADSPEC=""
        for mt_s in "" abc 0x8000 0x8000: 0x8000:0 :0x10 -1:4 " 1:2" 0x8000:-5 0x8000:0x1000x 0xffffffffffffffff:2 1:99999999999999999999999 99999999999999999999999:1; do
            [ "$(mt_parse "$mt_s")" = "PARSE bad" ] || MT_BADSPEC="$MT_BADSPEC [$mt_s]"
        done
        chk "영역 지정: 어긋난 형식은 전부 거부 (빈 값·크기 0·부호·공백·넘침·찌꺼기)"  "${MT_BADSPEC:-none}" "none"
        MT_G=$(env -u REHOST_MEMDUMP_REGION "$MT_EN/harness" guard 2>&1); MT_GRC=$?
        chk "영역 미지정: 종료코드 0"                                  "$MT_GRC" "0"
        chk "영역 미지정: 보호 꺼짐을 호스트 줄로 남긴다"                "$(printf '%s\n' "$MT_G" | grep -c 'LOG memdump guard: off (REHOST_MEMDUMP_REGION not set')" "1"
        chk "영역 미지정: 보호 범위 0 이라 쓰기가 막히지 않는다 (소스에는 영역이 없다)"  "$(printf '%s\n' "$MT_G" | grep '^GUARD' | tr '\n' ' ')" "GUARD 0 0 GUARD_WRITE 1 "
        MT_G=$(REHOST_MEMDUMP_REGION=0x8000:0x1000 "$MT_EN/harness" guard 2>&1); MT_GRC=$?
        chk "영역 지정: 보호 범위를 읽어 쓰기를 막는다"                  "$MT_GRC/$(printf '%s\n' "$MT_G" | grep '^GUARD' | tr '\n' ' ')" "0/GUARD 8000 1000 GUARD_WRITE 0 "
        chk "영역 지정: 보호 켜짐과 범위를 호스트 줄로 남긴다"            "$(printf '%s\n' "$MT_G" | grep -c 'LOG memdump guard: host-read region 0x8000 size 0x1000 is never written')" "1"
        MT_G=$(REHOST_MEMDUMP_REGION=0x8000 "$MT_EN/harness" guard 2>&1); MT_GRC=$?
        chk "영역 형식 오류: 머신이 멈춘다 (틀린 범위는 없는 것보다 나쁘다)"  "$MT_GRC/$(printf '%s\n' "$MT_G" | grep -c "ERR rehost: REHOST_MEMDUMP_REGION must be <base>:<size>")" "1/1"
    else
        bad "엔진 구간이 호스트 cc 로 컴파일된다" "$(head -5 "$MT_EN/cc.err")"
    fi
else
    printf '  \033[2mSKIP\033[0m 엔진 구간 실행 시험 (cc 없음)\n'
fi

# ---------------------------------------------------------------------------
# 템플릿을 실제 QEMU 헤더로 컴파일 (SBOOT_TEST_QEMU_TREE 가 있을 때만)
# ---------------------------------------------------------------------------
mt_fill() {   # $1 = 템플릿, $2 = 출력.  코드 위치의 자리표시자만 값을 채운다 (블록 자리는 주석 안이라 그대로)
    python3 - "$1" "$2" <<'PY'
import re, sys
s = open(sys.argv[1]).read()
code = re.sub(r'/\*.*?\*/', '', s, flags=re.S)
vals, i = {}, 0
for n in sorted(set(re.findall(r'\{\{([A-Z0-9_]+)\}\}', code))):
    if n in ('MODEL', 'MODEL_LOWER'): vals[n] = 'dummy'
    elif n.startswith('CPU') and n.endswith('TYPE'): vals[n] = 'cortex-a55'
    elif '_HAS_' in n or n.startswith('HAS_'): vals[n] = 'true'
    elif n == 'SMP': vals[n] = '1'
    elif n == 'GIC_REVISION': vals[n] = '3'
    elif n == 'GIC_NUM_IRQ': vals[n] = '288'
    elif n == 'HANDOFF_COPY_REGS': vals[n] = '4'
    elif n.endswith('_HZ'): vals[n] = '13000000'
    elif n.endswith('_STR') or n.endswith('_NAME'): vals[n] = 'dummy'
    else:
        i += 1; vals[n] = str(0x1000 * i)
for n, v in vals.items(): s = s.replace('{{%s}}' % n, v)
open(sys.argv[2], 'w').write(s)
PY
}
if [ -n "${SBOOT_TEST_QEMU_TREE:-}" ] && [ -f "$SBOOT_TEST_QEMU_TREE/build/build.ninja" ] && command -v ninja >/dev/null 2>&1; then
    MT_QT="$SBOOT_TEST_QEMU_TREE"; MT_MB="$MT_QT/hw/arm/meson.build"; cp "$MT_MB" "$MT_DIR/meson.build.bak"
    for pair in "full:$MT_T_FULL" "mixed:$MT_T_MIX"; do
        nm="rehost_tmpl_chk_${pair%%:*}"; mt_fill "${pair#*:}" "$MT_QT/hw/arm/$nm.c"
        printf "arm_common_ss.add(files('%s.c'))\n" "$nm" >> "$MT_MB"
    done
    ( cd "$MT_QT/build" && ninja build.ninja >/dev/null 2>&1 )
    for nm in full mixed; do
        obj=$(cd "$MT_QT/build" && ninja -t targets all 2>/dev/null | grep "hw_arm_rehost_tmpl_chk_${nm}\.c\.o" | head -1 | sed 's/: .*//')
        if [ -n "$obj" ] && ( cd "$MT_QT/build" && ninja "$obj" ) >"$MT_DIR/ninja_$nm.log" 2>&1; then
            ok "채운 $nm 템플릿이 QEMU 헤더로 컴파일된다 (경고 $(grep -c 'warning:' "$MT_DIR/ninja_$nm.log")건)"
        else
            bad "채운 $nm 템플릿이 QEMU 헤더로 컴파일된다" "$(grep -m3 'error' "$MT_DIR/ninja_$nm.log")"
        fi
    done
    cp "$MT_DIR/meson.build.bak" "$MT_MB"; rm -f "$MT_QT/hw/arm/rehost_tmpl_chk_full.c" "$MT_QT/hw/arm/rehost_tmpl_chk_mixed.c"
    ( cd "$MT_QT/build" && ninja build.ninja >/dev/null 2>&1; rm -f libsystem_arm.a.p/hw_arm_rehost_tmpl_chk_*.o )
else
    printf '  \033[2mSKIP\033[0m QEMU 헤더 컴파일 시험 (SBOOT_TEST_QEMU_TREE 미지정)\n'
fi

# ---------------------------------------------------------------------------
# 게이트 1 과의 합 — 채운 템플릿을 memdump_plan.json 의 영역으로 실제 게이트에 넣는다
# (게이트 1 은 보호 영역 안의 정수 상수를 하나라도 찾으면 실패한다. 영역을 상수로 품은
#  템플릿은 memdump 채널이 켜진 정직한 머신도 게이트 1 을 통과하지 못한다.)
# ---------------------------------------------------------------------------
MT_GATE="$MT_DIR/gate1"; mkdir -p "$MT_GATE/ws"
MT_RBASE=0x70000000; MT_RSIZE=262144      # 합성 영역 — 기기 값이 아니다
printf '{"channel":"memdump","region_base":"%s","region_size":%s,"console_size":65536,"source":"cmdline","evidence":"synthetic"}\n' \
    "$MT_RBASE" "$MT_RSIZE" > "$MT_GATE/ws/memdump_plan.json"
# 템플릿이 영역 자리표시자를 요구하면 Build 는 계획의 값을 거기에 채운다 — 같은 일을 시험이 한다
# (나머지 자리표시자는 mt_fill 이 채운다)
cp "$MT_T_MIX" "$MT_GATE/tmpl.in"
for mt_n in $(grep -o '{{MEMDUMP_[A-Z0-9_]*}}' "$MT_T_MIX" | tr -d '{}' | sort -u); do
    case "$mt_n" in *SIZE*) mt_v="$MT_RSIZE";; *) mt_v="$MT_RBASE";; esac
    sed -i.bak "s/{{$mt_n}}/$mt_v/g" "$MT_GATE/tmpl.in"; rm -f "$MT_GATE/tmpl.in.bak"
done
mt_fill "$MT_GATE/tmpl.in" "$MT_GATE/filled.c"
MT_RANGE=$(PYTHONDONTWRITEBYTECODE=1 python3 -c "import sys; sys.path.insert(0, sys.argv[1]); import verify_gates as vg; print(','.join('%#x:%#x' % r for r in vg.plan_ranges(sys.argv[2])))" "$S" "$MT_GATE/ws")
chk "게이트 합: 계획에서 읽은 보호 범위"                         "$MT_RANGE" "$(printf '%#x:%#x' "$MT_RBASE" "$MT_RSIZE")"
: > "$MT_GATE/console.txt"
mt_scan() {   # $1 = 소스 -> "ok/보호 영역 참조 수"
    PYTHONDONTWRITEBYTECODE=1 python3 "$S/verify_gates.py" scan --console "$MT_GATE/console.txt" \
        --protected-ranges "$MT_RANGE" "$1" 2>/dev/null \
        | python3 -c 'import json,sys; d=json.load(sys.stdin); print("%s/%d" % (d["ok"], len(d["protected_hits"])))'
}
chk "게이트 합: 채운 템플릿은 보호 영역을 참조하지 않아 게이트 1 통과"   "$(mt_scan "$MT_GATE/filled.c")" "True/0"
chk "게이트 합: 템플릿에 영역을 담는 자리표시자·상수·표 행이 없다"      "$(grep -c 'MEMDUMP_BASE\|MEMDUMP_SIZE\|RES_MEMDUMP' "$MT_T_MIX")" "0"
# 대조: 옛 방식(영역을 상수로 품음)은 같은 게이트에서 실패한다 — 위 통과가 헛것이 아님을 보인다
cp "$MT_GATE/filled.c" "$MT_GATE/legacy.c"
printf '#define MEMDUMP_BASE %sULL\n#define MEMDUMP_SIZE %sULL\n' "$MT_RBASE" "$MT_RSIZE" >> "$MT_GATE/legacy.c"
chk "게이트 합 대조: 영역을 상수로 품은 소스는 게이트 1 실패"           "$(mt_scan "$MT_GATE/legacy.c")" "False/1"

# ---------------------------------------------------------------------------
# STATIC.md "주소 창" 표 — 템플릿이 참조하는 표의 정의가 템플릿 안에 있고 설계의 열과 같다
# ---------------------------------------------------------------------------
cat > "$MT_DIR/cols_tmpl.py" <<'PY'
import re, sys
t = open(sys.argv[1], encoding="utf-8").read()
i = t.find('STATIC.md "address windows" table. Every')
blk = t[i:t.index("*/", i)] if i >= 0 else ""
a, b = blk.find("Columns:"), blk.find("One row per")
cols = []
if a >= 0 and b > a:
    for ln in blk[a + len("Columns:"):b].splitlines():
        m = re.match(r"^ \*( {6})(\S.*)$", ln)       # 열 줄은 6칸, 이어지는 설명은 더 깊다
        if m:
            first = re.split(r"\s{2,}", m.group(2))[0]
            cols += [c.strip() for c in first.rstrip(",").split(",") if c.strip()]
print(",".join(cols))
PY
MT_COLS_TMPL=$(python3 "$MT_DIR/cols_tmpl.py" "$MT_T_MIX")
chk "주소 창 표: 템플릿이 열 열 개를 정의한다"                   "$MT_COLS_TMPL" "base,size,name,source,model,phase,kind,evidence,bypass,security_effect"
for mt_v in "shadow | override | dedicated | catchall" "pre_handoff | post_handoff | both" "dtb | disasm | observed | assumed" "M | V | S"; do
    chk "주소 창 표: 어휘 \"$mt_v\""                              "$(grep -c -- "$mt_v" "$MT_T_MIX" | awk '{print ($1>=1) ? "yes" : "no"}')" "yes"
done
chk "주소 창 표: security_effect 의 뜻(서명 검증 경로)이 적혀 있다"    "$(grep -c 'security_effect  true when the firmware reads the value on a signature-verification' "$MT_T_MIX")" "1"
# 표를 가리키는 곳은 정의 한 곳과 참조 세 곳 (섀도우 · 읽기 덮어쓰기 · 전용 모델) — 정의 없는 참조가 아니다
chk "주소 창 표: 정의 1 + 참조 3 (섀도우·읽기 덮어쓰기·전용 모델)"     "$(grep -c 'STATIC.md "address windows" table' "$MT_T_MIX")" "4"

# ---------------------------------------------------------------------------
# 참조 예제 examples/a136u-mt6833
# ---------------------------------------------------------------------------
chk "예제: 네 파일이 있다 (펌웨어 없음)"            "$(LC_ALL=C ls "$MT_EX" | tr '\n' ' ')" "EXPECTED_MILESTONES.txt README.md bypasses.md machine.c "
chk "예제: 펌웨어·이미지 바이너리가 없다"             "$(find "$MT_EX" -type f \( -name '*.img' -o -name '*.bin' -o -name '*.tar*' -o -name '*.zip' -o -name '*.lz4' -o -name '*.gz' \) | wc -l | tr -d ' ')" "0"
chk "예제: 폴더 전체가 500 KB 이하 (펌웨어가 들어갈 수 없는 크기)"  "$([ "$(cat "$MT_EX"/* | wc -c | tr -d ' ')" -le 512000 ] && echo yes || echo no)" "yes"
chk "예제: machine.c 경고가 앞부분에 있다"            "$(head -12 "$MT_EX/machine.c" | grep -c 'REFERENCE ONLY - VALUES ARE NOT BORROWABLE')" "1"
MT_FIRST_CLOSE=$(grep -n '\*/' "$MT_EX/machine.c" | head -1 | cut -d: -f1)
chk "예제: machine.c 경고는 첫 줄에서 열려 주석 하나로 끝난다"  "$([ "$(head -1 "$MT_EX/machine.c")" = "/*" ] && [ -n "$MT_FIRST_CLOSE" ] && [ "$MT_FIRST_CLOSE" -lt 40 ] && echo closed || echo no)" "closed"
chk "예제: 경고 뒤에 원 소스 헤더 주석이 이어진다"      "$(awk '/\*\//{f=1;next} f&&NF{print; exit}' "$MT_EX/machine.c")" "/*"
chk "예제: 경고가 낡은 v1 헤더 주석을 짚는다"          "$(grep -c 'header comment right below is STALE' "$MT_EX/machine.c")" "1"
chk "예제: 경고가 검증 우회를 말한다"                  "$(grep -c 'Verification was bypassed' "$MT_EX/machine.c")" "1"
chk "예제: 경고가 펌웨어 미포함을 말한다"               "$(grep -c 'NOT part of this repository' "$MT_EX/machine.c")" "1"
chk "예제: 소스는 키트 머신 그대로 (타입 이름이 남아 있다)" "$(grep -c 'rehost-sma136ua136usqsfdyj1-preloader' "$MT_EX/machine.c" | awk '{print ($1>=1) ? "yes" : "no"}')" "yes"
for t in "값을 차용하지 않는다" "펌웨어는 이 저장소에 없다" "낡은 값이 남아 있다" "reached_bypassed" "검증을 우회했다" "검증되지 않은 우회" "참조 자료"; do
    chk "예제 README: \"$t\""                         "$(grep -c -- "$t" "$MT_EX/README.md" | awk '{print ($1>=1) ? "yes" : "no"}')" "yes"
done
chk "예제 bypasses.md: 맨 위에 알려진 결함 (#65 훼손)"   "$(head -12 "$MT_EX/bypasses.md" | grep -c '#65 가 훼손')" "1"
chk "예제 bypasses.md: 맨 위에 부작용 기록 없음 22개"     "$(head -16 "$MT_EX/bypasses.md" | grep -c '22개')" "1"
chk "예제 bypasses.md: 원문 92 항목 그대로"             "$(grep -c '^## #' "$MT_EX/bypasses.md")" "92"
chk "예제 bypasses.md: 부작용이 비어 있는 항목은 정확히 22개" "$(grep -c '^- \*\*부작용\*\*: (기록 없음)' "$MT_EX/bypasses.md")" "22"
# 마일스톤 파일: 데이터 줄은 탭 3열 (설계 C2), 채널은 uart|memdump, 바이너리 바이트 없음
chk "예제 마일스톤: 데이터 줄 형식 <milestone>\\t<token>\\t<channel>" \
    "$(grep -v '^#' "$MT_EX/EXPECTED_MILESTONES.txt" | awk -F'\t' 'NF==3 && ($3=="uart"||$3=="memdump"){ok++} NF!=3 || !($3=="uart"||$3=="memdump"){bad++} END{print (ok>0 && bad==0) ? "ok" : "bad"}')" "ok"
MT_MS="$MT_EX/EXPECTED_MILESTONES.txt"
chk "예제 마일스톤: kernel_alive 는 모두 memdump 채널"      "$(awk -F'\t' '$1=="kernel_alive" && $3!="memdump"' "$MT_MS" | wc -l | tr -d ' ')/$(awk -F'\t' '$1=="kernel_alive"' "$MT_MS" | wc -l | tr -d ' ')" "0/3"
chk "예제 마일스톤: kernel_entry 는 uart 채널"            "$(awk -F'\t' '$1=="kernel_entry" && $3!="uart"' "$MT_MS" | wc -l | tr -d ' ')/$(awk -F'\t' '$1=="kernel_entry"' "$MT_MS" | wc -l | tr -d ' ')" "0/1"
chk "예제 마일스톤: 필수 칸이 있다"                       "$(for m in preloader_entry lk_entry medium_up partitions verify_ok kernel_entry kernel_alive userspace partitions_up super_mounted; do awk -F'\t' -v m="$m" '$1==m{f=1} END{exit !f}' "$MT_MS" && echo y; done | wc -l | tr -d ' ')" "10"
chk "예제 마일스톤: 탭·개행 외 제어 문자와 NUL 이 없다 (펌웨어 바이트 아님)"  "$(LC_ALL=C tr -d '\11\12\40-\377' < "$MT_MS" | wc -c | tr -d ' ')" "0"
chk "예제 마일스톤: 검증 우회 주의가 적혀 있다"            "$(grep -c 'verify_ok 줄은 검증을 우회한 상태에서 찍혔다' "$MT_EX/EXPECTED_MILESTONES.txt")" "1"

# ---------------------------------------------------------------------------
# storage_hci.c.tmpl: Exynos UFS 골격 — 값은 자리표시자, 이름표는 중립 (CC5)
# ---------------------------------------------------------------------------
MT_T_STO="$REPO/templates/storage_hci.c.tmpl"
mt_sto_code() {   # 주석을 뺀 코드만
    python3 -c 'import re,sys; print(re.sub(r"/\*.*?\*/", "", open(sys.argv[1], encoding="utf-8").read(), flags=re.S))' "$MT_T_STO"
}
chk "storage: 머리 주석이 Exynos UFS 골격이고 UFS 전용이라고 말한다" \
    "$(head -12 "$MT_T_STO" | grep -c 'Exynos UFS 골격 (UFS 전용')" "1"
chk "storage: 머리 주석이 창 이름·반환값은 도출할 예시라고 말한다" \
    "$(head -24 "$MT_T_STO" | tr '\n' ' ' | grep -c '벤더 창 이름.*전부 "예시"다.*도출한다')" "1"
chk "storage: '모든 ready 비트'·all-ones 반환값이 코드에 박혀 있지 않다" \
    "$(mt_sto_code | grep -ciE 'return +0x0*f;|return +0xffffffff;')" "0"
chk "storage: ready 상태·PHY 완료 값은 자리표시자다" \
    "$(mt_sto_code | grep -c 'return {{HCS_READY_VALUE}};\|return {{PHY_CAL_DONE_VALUE}};')" "2"
chk "storage: 벤더 창 이름은 코드에 문자열로 박혀 있지 않고 자리표시자다" \
    "$(mt_sto_code | grep -c '"phy"\|"uni"\|"pcs"')/$(mt_sto_code | grep -c '{{PHY_WIN_NAME}}\|{{UNI_WIN_NAME}}')" "0/2"
chk "storage: 코드에 SoC·제조사 이름표(e2400 · Exynos · eufs_ · ExynosUfs)가 없다" \
    "$(mt_sto_code | grep -c 'e2400\|[Ee]xynos\|[Ss]amsung\|eufs_\|EufsWin')" "0"
chk "storage: 환경변수 이름은 export 키트와 같다 (바꾸면 키트가 매체를 못 찾는다)" \
    "$(grep -c 'EUFS_LU_IMAGE' "$MT_T_STO" | awk '{print ($1>=1)?"t":"f"}')$(grep -c 'EUFS_LBS' "$MT_T_STO" | awk '{print ($1>=1)?"t":"f"}')$(grep -c 'EUFS_LU_IMAGE' "$S/make_export.sh" | awk '{print ($1>=1)?"k":"x"}')" "ttk"
chk "storage: 기본 논리 블록 크기도 박지 않는다 (합성 매체의 block_size 에서 도출)" \
    "$(mt_sto_code | grep -c 'atoi(getenv("EUFS_LBS")) : {{LU_BLOCK_SIZE}}')/$(mt_sto_code | grep -c ': 4096')" "1/0"
if command -v cc >/dev/null 2>&1; then
    # 채운 골격이 문법상 맞는가: QEMU 헤더 대신 합성 스텁 헤더로 구문만 본다 (실제 QEMU 로 컴파일한 것은 아니다)
    MT_ST="$MT_DIR/storage"; mkdir -p "$MT_ST/qemu" "$MT_ST/hw" "$MT_ST/system"
    cat > "$MT_ST/qemu/osdep.h" <<'MT_STUB_EOF'
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/types.h>
typedef uint64_t hwaddr;
typedef struct MemoryRegion { int unused; } MemoryRegion;
typedef struct IrqState *qemu_irq;
void qemu_set_irq(qemu_irq irq, int level);
typedef struct MemoryRegionOps {
    uint64_t (*read)(void *, hwaddr, unsigned);
    void (*write)(void *, hwaddr, uint64_t, unsigned);
    int endianness;
} MemoryRegionOps;
#define DEVICE_LITTLE_ENDIAN 1
#define MEMTXATTRS_UNSPECIFIED 0
extern int address_space_memory;
int dma_memory_read(int *as, uint64_t addr, void *buf, uint64_t len, int attrs);
static inline uint32_t ldl_le_p(const void *p) { uint32_t v; memcpy(&v, p, 4); return v; }
MT_STUB_EOF
    : > "$MT_ST/qemu/log.h"; : > "$MT_ST/hw/irq.h"; : > "$MT_ST/system/dma.h"
    cat > "$MT_ST/stub_ufs_hci.h" <<'MT_STUB_EOF'
typedef struct UfsHci { uint32_t reg[64]; qemu_irq irq; int backing_fd; off_t lu_size; int lbs; } UfsHci;
typedef struct UfsHciWin { UfsHci *u; const char *name; } UfsHciWin;
#define UFS_HCI_MEM_REGS 64
void ufs_hci_uiccmd(UfsHci *u, uint32_t cmd);
void ufs_hci_ring_doorbell(UfsHci *u, uint32_t slots);
uint32_t ufs_hci_unipro_attr(uint32_t attr);
uint32_t ufs_hci_vendor_val(UfsHci *u, const char *win, hwaddr off);
void ufs_hci_reply_nop(UfsHci *u, uint64_t ucd);
void ufs_hci_handle_query(UfsHci *u, uint64_t ucd, const uint8_t *upiu);
void ufs_hci_handle_scsi(UfsHci *u, uint64_t ucd, const uint8_t *upiu);
MT_STUB_EOF
    sed 's/{{STORAGE_HCI_HEADER}}/stub_ufs_hci.h/g' "$MT_T_STO" > "$MT_ST/tmpl.in"
    mt_fill "$MT_ST/tmpl.in" "$MT_ST/storage_hci.c"
    if ( cd "$MT_ST" && cc -std=gnu11 -fsyntax-only -Werror=implicit-function-declaration -I. storage_hci.c ) >"$MT_ST/cc.log" 2>&1; then
        ok "storage: 채운 골격이 스텁 헤더로 구문 검사를 통과한다 (이름을 바꾸다 남긴 옛 이름이 없다)"
    else
        bad "storage: 채운 골격이 스텁 헤더로 구문 검사를 통과한다" "$(grep -m3 'error' "$MT_ST/cc.log")"
    fi
    chk "storage: 채우지 않은 자리표시자가 코드에 남지 않았다 (시험의 채움이 빠뜨린 것 없음)" \
        "$(python3 -c 'import re,sys; print(len(re.findall(r"\{\{[A-Z0-9_]+\}\}", re.sub(r"/\*.*?\*/", "", open(sys.argv[1]).read(), flags=re.S))))' "$MT_ST/storage_hci.c")" "0"
else
    printf '  \033[2mSKIP\033[0m storage 골격 구문 검사 (cc 없음)\n'
fi

# ---------------------------------------------------------------------------
# 정리 + 문법
# ---------------------------------------------------------------------------
chk "patch_qemu_core.py 문법"                           "$(python3 -c "import ast,sys; ast.parse(open('$MT_PQ').read()); print('ok')" 2>&1)" "ok"
rm -rf "$MT_DIR"
chk "시험이 남긴 파일이 저장소에 없다"                    "$(cd "$REPO" && git status --porcelain -- scripts templates examples 2>/dev/null | grep -c '__pycache__\|\.sboot_touched\|\.bak')" "0"

parts_finish
