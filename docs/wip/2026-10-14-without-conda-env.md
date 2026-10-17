# conda 없이 unitree_sim_isaaclab 환경 구축 (WIP)

- 기간: 2026-10-14 ~ 2026-10-17
- 브랜치: `without-conda-env` (커밋 `494d50b`)
- 대상 시스템: Ubuntu 24.04, RTX 3090 (드라이버 580), conda 미설치, `uv` 0.11.19 설치됨

## 1. 목적

1. README 기준으로 이 프로젝트의 빌드 및 실행 방법을 파악한다.
2. conda가 설치되지 않은 시스템에서 conda가 필수인지 확인하고, 필수가 아니라면 conda 없이 환경을 구축한다.
3. `auto_setup_env.sh`의 conda-free 버전(`auto_setup_env_wo_conda.sh`)을 만들고 실제로 수행되는지 검증한다.
4. 설치 과정에서 Isaac Sim을 별도로 설치하지 않아도 되는지 확인한다.
5. (부가) Isaac Sim을 MuJoCo처럼 C++로 제어할 수 있는지 조사한다.

## 2. 결론 요약

| 질문 | 결론 |
|---|---|
| conda가 필수인가? | **아니다.** conda는 (1) Python 3.11 격리 환경 생성, (2) `libstdcxx-ng` 패치에만 쓰인다. (1)은 uv venv로 대체하고, (2)는 conda가 번들한 오래된 libstdc++ 문제라 venv(시스템 libstdc++ 사용)에서는 필요 없다. |
| Isaac Sim 설치를 생략할 수 있나? | **없다.** `isaaclab.sh --install`(v2.3.2)은 torch와 Isaac Lab 패키지만 설치하고 isaacsim은 설치하지 않는다. `sim_main.py`가 `isaaclab.app.AppLauncher`를 쓰고, 이것이 내부적으로 Isaac Sim을 띄우므로 반드시 필요하다. |
| Isaac Sim은 소스 빌드했나? | 아니다. NVIDIA PyPI의 pip wheel(`isaacsim[all,extscache]==5.1.0`)을 venv의 site-packages에 설치했다. 소스 빌드한 것은 CycloneDDS 하나뿐이다. |
| 결과 | 설치 스크립트가 exit 0으로 끝났고, 시뮬레이터를 실행해 DDS `rt/lowstate`가 약 100Hz로 발행되는 것까지 확인했다. |

## 3. 수행 내용

### 3.1 README와 설치 문서 분석

- README, `doc/isaacsim5.1_install.md`, `auto_setup_env.sh`, `Dockerfile`, `requirements.txt`, `fetch_assets.sh`를 읽었다.
- 설치 흐름: submodule(teleimager) 초기화 → 인증서 생성 → 에셋 다운로드 → CycloneDDS 빌드 → Python 환경 생성 → torch → isaacsim → Isaac Lab → unitree_sdk2_python → requirements, teleimager
- 실행 예 (텔레오퍼레이션):
  ```bash
  python sim_main.py --device cpu --enable_cameras --task Isaac-PickPlace-Cylinder-G129-Dex1-Joint --enable_dex1_dds --robot_type g129
  ```
- Docker 방식은 이미지 안에 Miniconda를 설치하므로 호스트에는 conda가 필요 없다. 이 시스템에는 nvidia-container-toolkit 1.20.1이 있다.

### 3.2 사전 조사에서 발견한 문제

- **IsaacLab `main`이 3.0.0이고 Isaac Sim 6.2를 요구한다.** 원래 스크립트는 5.1용 IsaacLab을 고정하지 않고 clone하므로 버전이 맞지 않는다. 문서에 적힌 커밋 `80094be3`이 v2.3.2이므로 이것으로 고정했다.
- 이 시스템에는 `python3.11-dev`가 없다. cyclonedds 파이썬 패키지의 C 확장 빌드에 `Python.h`가 필요하다. 그래서 `Python.h`가 들어 있는 uv-managed Python을 써서 apt 설치(sudo)를 피했다.
- `sudo`에 비밀번호가 필요하다. 그래서 시스템 패키지는 빠진 것이 있을 때만 apt로 설치하도록 했다. 이 시스템에서는 모두 설치돼 있었다.
- IsaacLab v2.3.2의 `--install`은 torch를 `2.7.0+cu128`로 다시 설치한다. 그래서 5.1의 기본 CUDA를 cu126 대신 cu128로 맞췄다.

### 3.3 `auto_setup_env_wo_conda.sh` 작성

원래 `auto_setup_env.sh`와의 차이:

| 항목 | 원래 (conda) | 변경 (uv venv) |
|---|---|---|
| Python 환경 | `conda create -n <env> python=3.11` | `uv venv --seed --managed-python`, 위치는 `${VENV_ROOT:-$HOME/.venvs}/<env>` |
| 패키지 설치 | `pip install` | `uv pip install` (isaacsim은 `--index-strategy unsafe-best-match`) |
| libstdc++ | `conda install libstdcxx-ng` | 시스템 libstdc++에 `GLIBCXX_3.4.30`이 있는지만 검사 |
| IsaacLab 버전 | 5.0만 v2.2.0, 나머지는 `main` | 4.5는 v2.1.0(`91ad494`), 5.0은 v2.2.0, 5.1은 v2.3.2(`80094be3`)로 고정 |
| 시스템 패키지 | 항상 `sudo apt-get install` | 빠진 것만 설치 |
| 인증서 | openssl 대화형 프롬프트 | `-subj "/CN=localhost"`로 비대화형 생성, 이미 있으면 건너뜀 |
| 에셋 | 매번 다시 받음 | `assets/`가 있으면 건너뜀 |
| EULA | 대화형으로만 가능 | 비대화형으로 실행하면 `OMNI_KIT_ACCEPT_EULA=YES`를 요구 |
| pyarrow | 고정 없음 | `pyarrow<21`로 고정 |

사용법:

```bash
# 대화형 (EULA 프롬프트에 직접 Yes)
bash auto_setup_env_wo_conda.sh 5.1 unitree_sim_env

# 비대화형
VENV_ROOT=/hdd/Project/_unitree/.venvs OMNI_KIT_ACCEPT_EULA=YES \
  bash auto_setup_env_wo_conda.sh 5.1 unitree_sim_env

source /hdd/Project/_unitree/.venvs/unitree_sim_env/bin/activate
```

### 3.4 실제 실행과 수정 (3회 실행)

| 회차 | 결과 | 원인 | 조치 |
|---|---|---|---|
| 1 | exit 1 (Isaac Lab 설치 마지막 단계) | `isaaclab.sh --install`의 VSCode 설정 단계가 Isaac Sim을 띄우면서 EULA 프롬프트가 나왔는데, 백그라운드 실행이라 EOF를 받음 | 비대화형일 때 `OMNI_KIT_ACCEPT_EULA=YES`를 요구하는 검사를 추가. 사용자 동의를 받고 EULA를 수락함 |
| 2 | exit 141 (SIGPIPE) | libstdc++ 검사의 `ldconfig -p \| awk '...exit'` 파이프가 `pipefail` 때문에 실패로 처리됨 | 파이프 중간에 일찍 종료하는 reader를 쓰지 않도록 수정 |
| 2 | `import rerun` 실패 | `rerun-sdk`가 최신 pyarrow 26을 설치하는데, 이 버전은 NumPy 2를 요구함. Isaac Sim은 numpy 1.26.4를 고정 | requirements 설치 시 `pyarrow<21`로 고정 (원래 conda 스크립트에서도 생기는 문제) |
| 3 | **exit 0** | | |

그 밖에 uv 캐시(`/`)와 venv(`/hdd`)가 서로 다른 파일시스템이라 생기는 hardlink 경고를 `UV_LINK_MODE=copy`로 없앴다.

### 3.5 설치 결과물 위치

```
/hdd/Project/_unitree/
├── unitree_sim_isaaclab/        # 이 저장소. assets/ (1.7GB) 다운로드됨
├── IsaacLab/                    # v2.3.2 (80094be3) checkout, venv에 editable 설치
├── cyclonedds/                  # releases/0.10.x, cmake 빌드 → cyclonedds/install
├── unitree_sdk2_python/         # venv에 editable 설치
└── .venvs/unitree_sim_env/      # uv venv (약 19GB), Python 3.11.15
    └── lib/python3.11/site-packages/isaacsim   # Isaac Sim 5.1.0 pip (9.9GB)
```

인증서는 `~/.config/xr_teleoperate/{cert,key}.pem`에 있다.

### 3.6 검증

- 패키지 import: torch 2.7.0+cu128 (`cuda.is_available() == True`), isaaclab 0.54.3, unitree_sdk2py 1.0.1, cyclonedds 0.10.2, teleimager, zmq, rerun, onnxruntime, aiortc
- 시뮬레이터 실행 (`--headless` 추가):
  ```bash
  OMNI_KIT_ACCEPT_EULA=YES python sim_main.py --device cpu --enable_cameras \
    --task Isaac-PickPlace-Cylinder-G129-Dex1-Joint --enable_dex1_dds --robot_type g129 --headless
  ```
  - `create environment success` 로그 확인
  - head 및 좌우 손목 카메라 3대(480x640 @ 30FPS)와 Image Server(ZMQ 55555~55557, WebRTC 60001~60003) 준비 완료
- DDS: 별도 프로세스에서 `ChannelFactoryInitialize(1)` 후 `rt/lowstate`를 구독하니 5초에 488개(약 100Hz)가 들어왔다. 관절 값도 정상이었다.
- 확인 후 시뮬레이터를 종료했다.

## 4. 부가 조사: Isaac Sim의 C++ 제어 가능성

조사 대상은 `/hdd/Project/_nvidia/` 아래의 isaacsim, isaaclab, isaaclab-arena, isaacsim-ros_workspace다.

- **Isaac Lab:** Python 파일 2,527개, C++ 파일 0개다. 순수 Python이라 C++ 제어와는 관계없다.
- **Isaac Sim ≤ 6.0.x (5.1 포함):** 공개된 로봇 제어 API는 Python(`isaacsim.core.*`)뿐이다. 내부 C++는 Kit 확장과 OmniGraph 노드 구현에 쓰이고, 외부용 공개 헤더는 거의 없다.
- **Isaac Sim ≥ 6.1.0:** `source/libraries/isaacsim`이 v6.1.0 GA(2026-09-10)에서 처음 추가됐다. git 태그로 확인했다. Kit, extension registry, OmniGraph 없이 단독으로 쓸 수 있는 C/C++ 라이브러리다.
  - `foundation/objects`: Stage, Prim, Camera, shapes
  - `foundation/prims/physics/Articulation.hpp`: `setDofPositionTargets`, `setDofVelocityTargets`, `setDofGains` 등
  - `physics/manager/PhysicsManager.hpp`: `configure(dt)`, `step(n)`, `getSimulatedTime()`
  - `ovsim`: in-process(local)와 원격 gRPC 클라이언트를 같은 API로 제공. `ControlPlaneService`(Create/Get/DeleteSimulation)와 `WorldStateService`(Read/WriteWorldState, ReadSimulationTime)가 있다.
  - 라이브러리 버전은 7.0.0a1(알파)이다. C++로 물리 스텝과 Articulation을 제어하는 예제는 찾지 못했다. 빌드나 실행은 하지 않았다.
- **Kit 기반 Isaac Sim의 외부 제어 인터페이스:** ROS 2(`isaacsim.ros2.bridge`), ZMQ(`isaacsim.zmq.*`), UCX(`isaacsim.ucx.*`), 사용자 정의 DDS(이 프로젝트의 방식)가 있다. WebRTC livestream은 화면 보기 전용이다.
- 이 프로젝트에서 C++로 제어하는 현실적인 방법은 `unitree_sdk2`(C++)로 DDS 토픽을 주고받는 것이다. 다만 비동기 통신이라 MuJoCo처럼 물리 스텝과 정확히 맞물리는(lockstep) 제어는 아니다.

## 5. 남은 작업과 참고 사항

- [ ] Isaac Sim 4.5와 5.0 경로는 실행해서 검증하지 않았다.
- [ ] README에 `auto_setup_env_wo_conda.sh` 안내를 추가하지 않았다.
- [ ] 브랜치를 원격에 push하지 않았다.
- [ ] (선택) Isaac Sim 6.1+의 C++ 라이브러리와 ovsim gRPC 서버를 빌드하고 실행해서 C++ 클라이언트로 제어하는 것을 검증한다.
- 이 저장소는 `tasks/utils/__pycache__/*.pyc`를 git으로 추적한다. 그래서 시뮬레이터를 실행하면 해당 파일이 수정된 것으로 잡힌다. 커밋 전에 `git checkout -- tasks/utils/__pycache__`로 되돌릴 것.
- `--headless` 없이 실행하면 `DISPLAY=:1`에 시뮬레이터 창이 뜬다. 메인 뷰는 PerspectiveCamera → Cameras → PerspectiveCamera에서 선택한다.
