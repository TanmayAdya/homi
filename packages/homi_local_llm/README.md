# Homi local runtime trial

This package is an explicit local-import experiment, not an accepted replacement
for the existing platform adapters. Default builds compile the management stub
without linking or loading llama.cpp. The default app still supports iOS 15 and
Android API 24. Trial builds require iOS 16.4 or Android arm64/API 28.
The verified Apple archive contains an iOS arm64 device slice and a macOS slice,
without an iOS simulator slice. The preparer derives `ios/llama.xcframework` by
filtering only the top-level manifest and copying the byte-identical verified iOS
slice. It checks its Mach-O dynamic-library type and every copied file. This avoids
CocoaPods rejecting the mixed-platform upstream archive. **The iOS trial supports
physical devices only**; default simulator builds do not include the runtime.

The shared C API uses llama.cpp release **b11889**, commit
`d854d98bae598388ecea1ed84396587e5edc326d`. Both platforms load the same official
**Qwen3-0.6B-Q8_0.gguf** from Qwen repository revision
`23749fefcc72300e3a2ad315e1317431b06b590a`. The exact artifact is 639,446,688 bytes,
SHA-256 `9465e63a22add5354d9bb4b99e90117043c7124007664907259bd16d043bb031`.
The model is Apache-2.0; llama.cpp is MIT. The prepare tool verifies pinned license
copies as well as artifact hashes. Source, framework, model and license downloads
remain in ignored local build caches; no model is bundled or downloaded by the app.

From the app root, explicitly prepare the runtime and optional model:

```sh
python3 tool/prepare_homi_local_llm.py --runtime --model
```

The model is written to `build/homi-local-llm/Qwen3-0.6B-Q8_0.gguf`. Copy it to the
device's local Files storage using an ordinary local transfer, then use the trial
Settings import action. Import checks the full size and SHA-256, syncs a temporary
file and atomically replaces the owned model. Files stay outside cloud backup.
No URL or remote-provider endpoint is accepted by this package. The Android picker
requests local files only; on iOS choose **On My iPhone**, since Files providers may
themselves fetch remote documents. Failed or cancelled imports preserve an
existing valid model when cancellation wins before the atomic commit. Cancellation
after that commit reports the already installed model truthfully. Interrupted
temporary files are removed on the next import. iOS import fails before replacing
the model if the folder or temporary file cannot be excluded from backup.

For an iOS trial build, both native and Dart selection must be explicit:

```sh
cd ios
HOMI_LLAMA_TRIAL=1 pod install
cd ..
HOMI_LLAMA_TRIAL=1 flutter build ios --debug --no-codesign --no-pub \
  --dart-define=HOMI_LLAMA_TRIAL=true
```

The Podfile and plugin podspec select iOS 16.4 only with that environment variable.
If the runner project fixes a lower deployment target, the trial Xcode invocation
must explicitly set `IPHONEOS_DEPLOYMENT_TARGET=16.4`. Return to a default build by
running `pod install` without the variable, then building without the Dart flag.
Do not leave trial Pods cached and label the result a default build.

For Android, explicitly provide both build selections:

```sh
cd android
JAVA_HOME=/Library/Java/JavaVirtualMachines/jdk-21.jdk/Contents/Home \
  ./gradlew --offline :homi_local_llm:assembleDebug -PhomiLlamaTrial=true
cd ..
ORG_GRADLE_PROJECT_homiLlamaTrial=true flutter build apk --debug --no-pub \
  --dart-define=HOMI_LLAMA_TRIAL=true --target-platform=android-arm64
```

The app and plugin require the `homiLlamaTrial=true` Gradle property for the API 28
trial. The plugin uses the existing NDK 28.2.13676358 and CMake 3.22.1. Default
builds must omit that property and the Dart define. `HOMI_LLAMA_TRIAL=1` is also
recognized by the plugin, but is not a substitute for the app's Gradle property.
The example uses this workstation's supported JDK 21; the shell's JDK 27 cannot
run the existing Gradle 8.14 setup. Use an appropriate local JDK rather than
changing the machine's global Java selection.

The Dart management API is `HomiLocalLlm.status()`, `importModel(requestId)`,
`deleteModel()`, `cancel(requestId)` and `unload()`. Import and inference IDs are
UUIDs. The app adapter implements `AssistantModel`, `ContextualAssistantModel` and
`ReleasableAssistantModel`. Its contextual response must be JSON with `text`,
`sourceIds` and optional `openSourceId`; only supplied source IDs are accepted.
The application still rechecks account, plan, revision and permission context.
Availability never silently falls back to another provider.

Native lifecycle operations are serialized; unloading returns busy while a
generation owns its model/context. Cancel checks run between batches of at most
128 tokens and individual output tokens. CPU decode also uses llama.cpp's abort
callback; Metal does not promise an interrupt inside a submitted GPU batch.
Leaving chat or backgrounding requests cancellation and releases the cached model.
Only trusted role delimiters are tokenized as control tokens. All user, history
and app data are tokenized without special-token parsing.

Import cancellation is checked between reads. A document provider stalled inside
a synchronous read can delay worker completion; cancellation does not forcibly
close that read from the UI thread. Choose an already local file for the trial.
This provider behavior needs a physical interruption check before acceptance.
The native `firstTokenMs` metric records an internally sampled token; this package
returns a complete response rather than a token stream. B3 must measure actual
first visible UI feedback separately and must not label this internal metric
first visible token latency.

The initial experiment bounds context to 2,048 tokens, reserves 384 output tokens,
and rejects a prompt over 1,664 tokens with `CONTEXT_LIMIT`. It never silently drops
sources or chat. The byte bound is 20,000 and the returned text bound is 9,600 bytes.
These limits are deliberately explicit and are not evidence that all real plans
fit. Increasing them requires measured device memory and latency evidence.

Host smoke and cancellation checks (fictional data only):

```sh
cmake -S packages/homi_local_llm/native -B build/homi-local-llm/host \
  -DHOMI_LLAMA_TRIAL=ON \
  -DHOMI_LLAMA_SOURCE_DIR="$PWD/build/homi-local-llm/source" \
  -DGGML_METAL=OFF -DGGML_BLAS=OFF -DCMAKE_BUILD_TYPE=Release
cmake --build build/homi-local-llm/host -j 4
build/homi-local-llm/host/homi_llm_smoke \
  build/homi-local-llm/Qwen3-0.6B-Q8_0.gguf
```

On October 26, 2026, this passed on the local Mac CPU: the fictional scan question
used 81 input/17 output tokens, first token 1.45 s, total 1.64 s on the repeat run.
Assertions verified cancellation and refusal to free a model while work is active.
The common C++ and JNI bridge also compiled for Android arm64/API 28; both native
iOS files passed clang syntax checks at default iOS 15 and trial iOS 16.4.
The Android plugin trial AAR build passed with Kotlin and JNI; it contained only
the arm64 `libhomi_llm.so`. A subsequent default plugin build passed and its AAR
contained **no native libraries**, confirming that a prior trial build does not
leave the runtime packaged in the default artifact. The default manifest retained
API 24. The host smoke also verified context overflow and cancellation before
worker startup. Reused extracted source and Apple binaries were verified against
their pinned archives.
A full unsigned iOS arm64 app trial build also passed with the derived framework
and an explicit iOS 16.4 target (`/tmp/homi-b-ios-trial-build.log`). This confirms
native linking and framework embedding; it does not establish a device launch.
These are build and host checks, not physical-device performance or B3 acceptance.

Required device evidence still includes cold/warm timing and peak memory, real
context capacity, all six supported languages, valid cited JSON quality, cancel
and background timing, import interruption and invalid checksum behavior, clear
and reimport, and chat-to-camera/room-scan handoff. No 1.7B model has been downloaded.

Primary sources: [llama.cpp release](https://github.com/ggml-org/llama.cpp/releases/tag/b11889),
[pinned Android guide](https://github.com/ggml-org/llama.cpp/blob/d854d98bae598388ecea1ed84396587e5edc326d/docs/android.md),
[official Qwen artifact](https://huggingface.co/Qwen/Qwen3-0.6B-GGUF/tree/23749fefcc72300e3a2ad315e1317431b06b590a).
