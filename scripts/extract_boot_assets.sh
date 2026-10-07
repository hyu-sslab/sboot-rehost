#!/usr/bin/env bash
. "$(dirname "$0")/wsl_bridge.sh"
# extract_boot_assets.sh — 커널 부팅 자산 추출 (일반, 표준 언팩).
# 펌웨어 tar/img 에서 Image / DTB / initrd / super 를 <workdir>/fw 로.
#
# 사용법:
#   extract_boot_assets.sh <workdir> <boot.img> [super.img.lz4|super.img] [dtb]
#   (super 와 dtb 는 빈 문자열("")로 건너뛸 수 있다 — 파이프라인이 그렇게 부른다)
#
# 도출 아님 — 표준 Android boot image + super 언팩. 같은 빌드 자산만.
#
# 비대화형이고 멱등이다. 질문하지 않고, 이미 적재된 워크스페이스에 같은 인자로 다시 돌려도
# 실패하지 않으며 fw/ 를 망가뜨리지 않는다 (파이프라인이 Analyze 앞에서 그대로 부른다).
#   - 새 자산은 <workdir>/fw/.stage.<pid> 에서 먼저 만들고, boot.img 해석이 끝난 뒤에만 fw/ 로 옮긴다.
#     중간에 실패하면 fw/ 는 이전 상태 그대로다 (반쯤 쓰인 Image 를 남기지 않는다).
#   - super 인자가 이미 fw/super.img 이거나, fw/super.img 가 원본보다 새로우면 다시 풀지 않는다
#     (수 GB 를 두 번 풀지 않기 위해서). raw 로 바꾸지 못한 sparse 는 다음 실행에서 다시 시도한다.
#   - fw/ 에서 이 스크립트가 만드는 것은 Image · initramfs.cpio.gz · dtb* · board.dtb · super.img 뿐이다.
#
# 종료코드:
#   0  boot.img 에서 커널 fw/Image 를 꺼냈다. DTB · 램디스크 · super 가 없거나 sparse 를 풀지 못한 것은
#      "★" 줄과 마지막 요약 줄로 알린다 — 종료코드가 아니라 fw/ 의 파일로 판단하면 된다
#   1  인자 부족
#   2  입력 파일이 없거나 읽을 수 없다 (boot.img, 지정한 super)
#   3  boot.img 를 해석하지 못했다 (Android boot image 가 아님, 손상, 커널이 없음, gzip 커널이 깨짐)
#   4  super 를 풀지 못했다 (lz4 없음, 해제 실패). 이때도 boot.img 쪽 자산은 이미 fw/ 에 있다
#
# 마지막 줄 (형식 고정):
#   assets: image=<0|1> dtb=<0|1> initrd=<0|1> super=<none|raw|sparse>
#
# UNPACK_BOOTIMG: 표준 도구 경로 (기본: PATH 의 unpack_bootimg). 없으면 python 헤더 파서로 대신한다.
set -e
WORKDIR="$1"; BOOTIMG="$2"; SUPER="$3"; DTBIN="$4"
if [ -z "$WORKDIR" ] || [ -z "$BOOTIMG" ]; then
    echo "Usage: $0 <workdir> <boot.img> [super.img.lz4|super.img] [dtb]" >&2
    exit 1
fi
if [ ! -f "$BOOTIMG" ] || [ ! -r "$BOOTIMG" ]; then
    echo "boot.img 를 읽을 수 없습니다: $BOOTIMG" >&2
    exit 2
fi
if [ -n "$SUPER" ] && { [ ! -f "$SUPER" ] || [ ! -r "$SUPER" ]; }; then
    echo "super 를 읽을 수 없습니다: $SUPER" >&2
    exit 2
fi

FW="$WORKDIR/fw"; mkdir -p "$FW"
rm -rf "$FW"/.stage.* 2>/dev/null || true          # 죽은 실행이 남긴 임시 폴더
STAGE="$FW/.stage.$$"; OUT="$STAGE/out"
mkdir -p "$OUT"
trap 'rm -rf "$STAGE"' EXIT

is_gzip()   { [ "$(od -An -tx1 -N2 "$1" 2>/dev/null | tr -d ' \n')" = "1f8b" ]; }
is_sparse() { [ "$(od -An -tx1 -N4 "$1" 2>/dev/null | tr -d ' \n')" = "3aff26ed" ]; }

echo "== boot.img 언팩 =="
UNPACK="${UNPACK_BOOTIMG:-unpack_bootimg}"
if command -v "$UNPACK" >/dev/null 2>&1; then
    if ! "$UNPACK" --boot_img "$BOOTIMG" --out "$STAGE/_boot" >/dev/null 2>"$STAGE/unpack.err"; then
        echo "  ★ unpack_bootimg 실패: $(head -c 300 "$STAGE/unpack.err" | tr '\n' ' ')" >&2
        exit 3
    fi
    if [ ! -s "$STAGE/_boot/kernel" ]; then
        echo "  ★ boot.img 에 커널이 없습니다" >&2
        exit 3
    fi
    # gzip 인지는 이름이 아니라 매직으로 가른다 (이름만 믿으면 raw 커널이 .gz 로 불려 풀리지 않는다)
    if is_gzip "$STAGE/_boot/kernel"; then cp "$STAGE/_boot/kernel" "$OUT/Image.gz"
    else cp "$STAGE/_boot/kernel" "$OUT/Image"; fi
    if [ -s "$STAGE/_boot/ramdisk" ]; then cp "$STAGE/_boot/ramdisk" "$OUT/initramfs.cpio.gz"; fi
    for d in "$STAGE/_boot"/dtb*; do
        if [ -f "$d" ]; then cp "$d" "$OUT/"; fi
    done
else
    echo "  unpack_bootimg 없음 — python 헤더 파싱 폴백"
    if ! python3 - "$BOOTIMG" "$OUT" <<'PY'
import sys,struct,os
b=open(sys.argv[1],'rb').read(); fw=sys.argv[2]
if b[:8]!=b'ANDROID!':
    sys.stderr.write("  ★ Android boot image 가 아닙니다 (ANDROID! 매직 없음)\n"); sys.exit(3)
def u32(o): return struct.unpack_from('<I',b,o)[0]
# header_version 은 0x28. v0 헤더는 이 자리에 다른 값(또는 0)을 쓰므로 범위를 벗어나면 v0 로 본다.
hv=u32(0x28)
if hv>4: hv=0
ks=u32(0x08)                                    # kernel size
if hv>=3:
    ps=4096; rs=u32(0x0c)                       # v3/v4: 페이지 4096 고정, page_size 필드 없음
else:
    ps=u32(0x24) or 4096; rs=u32(0x10)          # v0-v2: page size 는 0x24 (0x28 이 아니다)
if not (ps&(ps-1)==0 and 0x200<=ps<=0x40000):
    sys.stderr.write("  ★ page size %d 가 올바르지 않습니다\n"%ps); sys.exit(3)
def rup(n): return (n+ps-1)//ps*ps
ko=ps; ro=ko+rup(ks)
print("  header v%d page %d kernel"%(hv,ps),ks,"ramdisk",rs)
if ks==0 or ko+ks>len(b) or ro+rs>len(b):
    # 잘린 boot.img 에서 짧은 Image 를 꺼내 정상 자산처럼 적재하지 않는다
    sys.stderr.write("  ★ boot.img 가 헤더가 말한 크기보다 짧거나 커널이 없습니다 (kernel %d, ramdisk %d, 파일 %d B)\n"%(ks,rs,len(b))); sys.exit(3)
open(os.path.join(fw,'Image.gz' if b[ko:ko+2]==b'\x1f\x8b' else 'Image'),'wb').write(b[ko:ko+ks])
if rs: open(os.path.join(fw,'initramfs.cpio.gz'),'wb').write(b[ro:ro+rs])
if hv==2:                                       # v2: kernel, ramdisk, second, recovery dtbo, dtb 순
    ss=u32(0x18); rdo=u32(0x660); ds=u32(0x670)
    do=ro+rup(rs)+rup(ss)+rup(rdo)
    if ds and do+ds<=len(b): open(os.path.join(fw,'dtb'),'wb').write(b[do:do+ds])
PY
    then
        exit 3
    fi
fi

# gzip 커널 해제. gzip 의 종료코드는 0 정상, 1 오류, 2 경고다. 꼬리에 붙은 쓰레기(경고)는 허용하고,
# 오류는 풀린 만큼이 출력에 남아 있어도 실패다 (GNU gzip 은 끊긴 입력에서 그렇게 한다).
if [ -f "$OUT/Image.gz" ]; then
    rc=0
    gzip -dc "$OUT/Image.gz" > "$OUT/Image" 2>"$STAGE/gunzip.err" || rc=$?
    if { [ "$rc" -ne 0 ] && [ "$rc" -ne 2 ]; } || [ ! -s "$OUT/Image" ]; then
        echo "  ★ 커널 gzip 을 풀지 못했습니다: $(head -c 200 "$STAGE/gunzip.err" | tr '\n' ' ')" >&2
        exit 3
    fi
    rm -f "$OUT/Image.gz"
    echo "  gunzip Image"
fi
if [ ! -s "$OUT/Image" ]; then
    echo "  ★ 커널을 꺼내지 못했습니다" >&2
    exit 3
fi

echo "== DTB =="
if [ -n "$DTBIN" ] && [ -f "$DTBIN" ]; then
    cp "$DTBIN" "$OUT/board.dtb"; echo "  copied $DTBIN"
elif [ -n "$DTBIN" ]; then
    echo "  ★ 지정한 DTB 를 찾을 수 없음: $DTBIN"
fi

# boot.img 쪽 자산은 여기서 fw/ 로 옮긴다. 이후 단계(super)가 실패해도 이것은 남는다.
for f in "$OUT"/*; do
    if [ -f "$f" ]; then mv -f "$f" "$FW/"; fi
done
has_dtb=0
for f in "$FW"/*.dtb "$FW/dtb"; do
    if [ -s "$f" ]; then has_dtb=1; break; fi
done
if [ "$has_dtb" -eq 0 ]; then
    echo "  ★ DTB 미확보 — dtbo.img/별도 파티션에서 확보 필요 (매직 0xd00dfeed)"
fi

echo "== super =="
SUPER_STATE=none
SUPER_RC=0
if [ -n "$SUPER" ]; then
    if [ "$SUPER" -ef "$FW/super.img" ]; then
        echo "  이미 fw/super.img — 다시 풀지 않음"
    elif [ -s "$FW/super.img" ] && [ ! "$SUPER" -nt "$FW/super.img" ] && ! is_sparse "$FW/super.img"; then
        echo "  fw/super.img 가 원본보다 새로움 — 다시 풀지 않음"
    else
        case "$SUPER" in
          *.lz4)
            if ! command -v lz4 >/dev/null 2>&1; then
                echo "  ★ super 가 .lz4 인데 lz4 없음 — lz4 설치 필요" >&2
                SUPER_RC=4
            elif ! lz4 -d -f "$SUPER" "$STAGE/super.img" >/dev/null 2>&1; then
                echo "  ★ lz4 해제 실패: $SUPER" >&2
                SUPER_RC=4
            fi;;
          *) cp "$SUPER" "$STAGE/super.img";;
        esac
        # sparse 면 simg2img 필요 (표준 툴 또는 worked example 의 simg2img.py)
        if [ "$SUPER_RC" -eq 0 ] && is_sparse "$STAGE/super.img"; then
            if command -v simg2img >/dev/null 2>&1; then
                if simg2img "$STAGE/super.img" "$STAGE/super_raw.img"; then
                    mv -f "$STAGE/super_raw.img" "$STAGE/super.img"; echo "  simg2img"
                else
                    echo "  ★ simg2img 실패" >&2
                    SUPER_RC=4
                fi
            else
                echo "  ★ super 가 sparse 인데 simg2img 없음 — 표준 simg2img 설치 또는 worked example"
                echo "     (10_exynos2400_rehost/scripts/simg2img.py) 포팅 후 raw 변환 필요"
            fi
        fi
        if [ "$SUPER_RC" -eq 0 ] && [ -f "$STAGE/super.img" ]; then
            mv -f "$STAGE/super.img" "$FW/super.img"
        fi
    fi
    if [ -s "$FW/super.img" ]; then
        echo "  super -> $FW/super.img (system/vendor 카브는 liblp/lp_tool.py, EROFS 매직 0xe0f5e1e2)"
    fi
fi
if [ -s "$FW/super.img" ]; then
    if is_sparse "$FW/super.img"; then SUPER_STATE=sparse; else SUPER_STATE=raw; fi
fi

echo "== 결과 =="; ls -la "$FW" | grep -v '\.stage\.' || true
echo "다음: static-analyzer 가 DTB 로 머신 골격 + 커널 게이트 도출"
yn() { if [ -s "$1" ]; then echo 1; else echo 0; fi; }
echo "assets: image=$(yn "$FW/Image") dtb=$has_dtb initrd=$(yn "$FW/initramfs.cpio.gz") super=$SUPER_STATE"
exit "$SUPER_RC"
