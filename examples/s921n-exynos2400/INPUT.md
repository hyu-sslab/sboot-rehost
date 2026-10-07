# INPUT — 옛 슬롯표의 예 (SM-S921N)

> 통합 체인 이전의 슬롯 구성을 채운 예다 (`track` · `bl3_path` 같은 슬롯은 지금은 없다). 지금의 `INPUT.md` 는 `start` 가
> 워크스페이스에 쓴다 (CLAUDE.md §15). 값은 이 기기의 것이고 다른 펌웨어에는 쓰지 않는다. 구조를 보는 용도로만 둔다.

| 슬롯 | 값 |
|---|---|
| track | 1 |
| autonomous | true |
| model | SM-S921N |
| soc | Exynos 2400 (ARMv9) |
| build | S921NKSUEDZDR |
| target | A (help) |
| bl3_path | /path/to/<carved BL3 image> |
| workdir | /path/to/workdir |
| refs | (다른 분석가의 참조 구현. 이 저장소에 없다) |
| has_el3_guess | false |
| has_el2_guess | true |
| qemu_dir | ~/qemu-build/qemu-10.2.2 |

## 참고

이 기기에서 관측한 콘솔 출력의 예는 [EXPECTED_OUTPUT.txt](EXPECTED_OUTPUT.txt) 이다. 값의 예이지 통과 기준이 아니다.

다른 펌웨어에서 같은 구조를 만들려면 그 펌웨어의 이미지를 `_inbox/` 에 넣고 `/sboot-rehost:start` 를 부른다. 슬롯 값은 그 펌웨어에서
도출하며, 이 표의 값을 옮겨 적지 않는다.
