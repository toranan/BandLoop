# BandLoop Studio

음원 분석 결과를 인이어 연습 트랙과 드럼 악보 초안으로 변환하는 로컬 제작 도구입니다.

`Studio/Test/`는 로컬 분석과 렌더링 결과를 보관하며 Git에서 제외됩니다.

## 인이어 영상 생성

원곡, 정사각형 앨범 이미지, 제목, 가수를 넣으면 다음 순서로 처리합니다.

1. `allin1-mlx`로 beat·downbeat·section 분석
2. 한국어 시작 카운트와 섹션 cue 생성
3. 클릭과 cue를 음원에 합성
4. 음원 3종, timeline JSON, 1080p MP4 출력

```bash
python3 Studio/Scripts/make_iem_video.py \
  /path/to/song.mp3 \
  /path/to/album-image.jpg \
  --title "Song title" \
  --artist "Artist" \
  --slug song-title
```

기본 출력 위치는 `Studio/Test/<slug>/`입니다.

- 분석 결과를 다시 쓰려면 `--analysis-json`
- 직접 검수한 구간을 쓰려면 `--cue-config`
- 생성한 목소리를 재사용하려면 `--voice-dir`
- BPM이 고정된 곡은 `--fixed-bpm 92`

자동으로 붙은 section 이름과 경계는 초안입니다. 업로드 전 cue JSON을 직접 확인해야 합니다.

### 인이어 음원만 다시 생성

```bash
python3 Studio/Scripts/render_iem_track.py \
  /path/to/analysis.json \
  /path/to/cues.json \
  /path/to/song.mp3 \
  /path/to/voice-directory \
  /path/to/output-directory \
  --slug song-title
```

`render_iem_track.py`는 ‘곡 시작’ 안내, 예비 클릭 2박, `하나 / 둘 / 셋 / 넷` 한 마디, 연속 클릭, 섹션 cue를 배치합니다. 48 kHz AAC로 다음 파일을 만듭니다.

- 원곡 + 클릭 + cue
- 클릭 + cue
- 좌채널 원곡 / 우채널 guide
- cue와 박자 시간이 든 timeline JSON

## 드럼 채보 초안

### 1. onset 추론

미리 분리한 drum stem과 ADTOF Frame_RNN 가중치가 필요합니다. 이 저장소는 stem 분리를 수행하지 않습니다.

```bash
python3 Studio/Scripts/transcribe_drums_adtof.py \
  /path/to/drums.wav \
  /path/to/model-weights.pt \
  /path/to/raw-output \
  --device mps
```

긴 음원은 20초 chunk와 2초 context로 나눠 추론합니다. CPU·MPS·CUDA를 선택할 수 있고, 선택한 장치를 쓸 수 없으면 CPU로 돌아갑니다.

출력:

- float16 raw activation NPZ
- confidence·velocity가 포함된 raw event JSON
- General MIDI

### 2. 악보 자산 생성

`build_drum_score.py`는 onset을 분석한 16분음표 그리드에 정렬하고 JSON·MIDI·MusicXML·PDF를 만듭니다. `--video`를 추가하면 원곡과 동기화된 1080p/30 fps 스크롤 영상도 생성합니다.

`build_drum_staff_preview.py`는 onset 주변의 주파수 특징을 활용해 high/mid/low/floor tom, ride/crash, open/closed hi-hat 후보를 보정합니다.

현재 결과는 연주자가 수정해야 하는 AI 초안입니다. 특히 cymbal 종류, open hi-hat, ghost note는 원본 분리 품질과 5-class 모델의 한계를 크게 받습니다.

## 필요 환경

- macOS `say`
- FFmpeg / ffprobe
- Python 3
- IEM: `allin1-mlx`, NumPy, SoundFile
- Drum: PyTorch, `adtof-pytorch`, PrettyMIDI, librosa, Pillow

## 검증

```bash
python3 -m compileall Studio/Scripts
```
