# Storage Swipe

**Clear your camera roll the way you clear your dating app inbox: one decisive swipe at a time.**

Storage Swipe is a Flutter app that turns the tedious, guilt-inducing chore of
"go delete some old photos" into a fast, game-like loop: a photo appears,
you swipe right to keep it or left to bin it, and a running tally shows you
exactly how much space you're about to reclaim.

This README is written as a **learning guide**, not just a reference. If
you're new to the codebase — or new to MVVM/Riverpod in Flutter generally —
read this top to bottom before you start changing code.

---

## Table of Contents

1. [The "Why" and "How"](#1-the-why-and-how)
2. [Architecture Breakdown (MVVM)](#2-architecture-breakdown-mvvm)
3. [Data Flow: A Photo's Life Story](#3-data-flow-a-photos-life-story)
4. [Backend Vision: Semantic Search](#4-backend-vision-semantic-search)
5. [Robustness: Empty States & the Review-Again Loop](#5-robustness-empty-states--the-review-again-loop)
6. [On-Device Semantic Search Pipeline](#6-on-device-semantic-search-pipeline)
7. [Project Structure](#7-project-structure)
8. [Getting Started](#8-getting-started)
9. [Key Design Decisions & Trade-offs](#9-key-design-decisions--trade-offs)

---

## 1. The "Why" and "How"

### The problem

Manually deleting photos to free up storage is a chore with a bad
feedback loop: you open the Photos app, scroll, long-press, select,
delete, repeat — and you rarely get a sense of *progress*. There's no
score, no momentum, and it's easy to quit after 10 photos and never come
back.

### The gamification hook

Storage Swipe borrows three mechanics from swipe-based dating apps and
casual mobile games, because they're specifically engineered to make
repetitive binary decisions feel effortless:

| Mechanic | In a dating app | In Storage Swipe |
|---|---|---|
| **Binary decision** | Like / Pass | Keep / Delete |
| **Physical feedback** | Card flies off-screen | Card flies off-screen |
| **Visible progress** | "X profiles left today" | "X of Y photos reviewed", MB tally |
| **Biggest wins first** | — | Largest files are queued first, so early swipes feel high-impact |

Sorting by **file size, descending**, is the single most important
gamification decision in this app. A user who clears three 80 MB video
screenshots in their first ten swipes *feels* like they're making
progress much faster than one who starts with a hundred 200 KB icons.
That's why `GalleryService.fetchBatch` always sorts each page
largest-first before it ever reaches the UI.

### The safety net: deletion is staged, not immediate

Swiping left never deletes anything. It only moves a photo into an
in-memory **trash buffer**. The user has to explicitly visit the Trash
screen and tap "Empty Trash" — with a confirmation dialog — before a
single byte is actually removed from the device. This mirrors how a
desktop OS Trash/Recycle Bin works, and it means a mis-swipe is never
catastrophic.

---

## 2. Architecture Breakdown (MVVM)

Storage Swipe uses **Layered MVVM**: Model, View, ViewModel, with a
Data layer sitting underneath the Model to own I/O. Each layer only
knows about the layer directly below it — a **View never talks to a
Service**, and a **Service never knows a `Widget` exists**.

```
┌─────────────────────────────────────────────────────────┐
│  ui/                     VIEW                            │
│  screens/, widgets/      "How does it look? What did the │
│                          user just do?"                  │
│                          Depends on: state/               │
└───────────────────────────┬───────────────────────────────┘
                             │ watches state, dispatches intents
┌───────────────────────────▼───────────────────────────────┐
│  state/                  VIEWMODEL                        │
│  swipe_provider.dart     "What SHOULD happen when the     │
│                          user keeps/deletes/empties       │
│                          trash? What's the current state  │
│                          of the queue and buffer?"        │
│                          Depends on: data/                 │
└───────────────────────────┬───────────────────────────────┘
                             │ calls services, wraps results in models
┌───────────────────────────▼───────────────────────────────┐
│  data/                   MODEL + DATA ACCESS               │
│  models/CustomAsset      "What IS a photo, and how do we   │
│  services/GalleryService  get/mutate it on the native      │
│  services/SemanticSearchApi  side or over the network?"    │
│                          Depends on: core/ (nothing app-   │
│                          specific)                          │
└───────────────────────────┬───────────────────────────────┘
                             │
┌───────────────────────────▼───────────────────────────────┐
│  core/                   FOUNDATION                        │
│  theme.dart              App-wide concerns with no         │
│  permissions_service.dart  knowledge of photos, swipes,    │
│                           or state at all.                  │
└─────────────────────────────────────────────────────────┘
```

### Model — `data/models/custom_asset.dart`

`CustomAsset` wraps `photo_manager`'s native `AssetEntity` and adds the
one piece of derived data the whole app cares about: **file size in
bytes**. Every other layer speaks in `CustomAsset`, never in raw
`AssetEntity`, so the rest of the app is insulated from `photo_manager`'s
API surface.

### Data / Services — `data/services/`

- **`GalleryService`** is the *only* file allowed to call
  `PhotoManager.*` directly. It owns pagination (`fetchBatch`,
  batches of 50) and native deletion (`deleteAssets`).
- **`SemanticSearchApi`** is a forward-looking stub for the planned
  FastAPI/FAISS backend (see [section 4](#4-backend-vision-semantic-search)).

### ViewModel — `state/swipe_provider.dart`

`SwipeController` (a Riverpod `StateNotifier<SwipeState>`) is the brain
of the app. It:

- Decides when to fetch the next batch (`loadNextBatch`, with
  prefetching so the user never sees a loading spinner mid-swipe).
- Decides what a swipe *means* (`keep` removes from the queue with no
  side effects and records it in `keptHistory`; `markForDeletion` moves
  the asset into `trashBuffer`).
- Owns the only path to real deletion (`emptyTrash`), including
  reconciling the buffer against what the OS actually confirmed
  deleting (the native deletion dialog can be cancelled by the user).
- Detects a genuinely empty library vs. a fully-reviewed queue
  (`isLibraryEmpty`, `isQueueExhausted`), and drives a repeatable
  "Review Kept Photos" second pass (`reviewKeptPhotos`).
- Applies and clears semantic-search filtering over the live queue
  (`applySemanticFilter`, `clearSemanticFilter`) without ever losing the
  unfiltered snapshot underneath it.

Because all of this logic lives in a plain Dart class with no Flutter
widget dependencies, **it's unit-testable without a device or emulator**
— you can construct a `SwipeController` with a fake `GalleryService` and
assert on `state` after calling `keep()`/`markForDeletion()`.

### View — `ui/screens/`, `ui/widgets/`

Screens (`SwipeScreen`, `TrashScreen`, `RecapScreen`) and widgets
(`PhotoCard`, `ActionButtons`) only do two things:

1. `ref.watch(swipeControllerProvider)` to read state and rebuild.
2. `ref.read(swipeControllerProvider.notifier).someMethod()` to report
   a user action.

If you ever see a `List.sort`, a byte-size calculation, or a
`PhotoManager` call inside a file under `ui/`, that's a bug — it means
business logic leaked out of the ViewModel.

---

## 3. Data Flow: A Photo's Life Story

Here's exactly what happens to a single photo, end to end:

1. **Native storage → Data layer.**
   `GalleryService._getRootAlbum()` asks `photo_manager` for the
   device's "All Photos" bucket. `fetchBatch(page)` pulls 50
   `AssetEntity` records for that page via `getAssetListPaged`.

2. **Data layer → Model.**
   Each raw `AssetEntity` is resolved into a `CustomAsset` via
   `CustomAsset.fromEntity`, which asynchronously stats the underlying
   file to get its real byte size. The batch is then sorted
   **descending by size**.

3. **Model → ViewModel (Riverpod state).**
   `SwipeController.loadNextBatch()` appends the sorted batch onto
   `SwipeState.pendingQueue` and increments `currentPage`. If the queue
   dips below a prefetch threshold, the next batch is silently
   requested in the background.

4. **ViewModel → UI (the swipe stack).**
   `SwipeScreen` watches `swipeControllerProvider` and renders
   `pendingQueue` through `flutter_card_swiper`'s `CardSwiper` widget,
   one `PhotoCard` per queued asset.

5. **UI gesture → ViewModel intent.**
   The user swipes. `CardSwiper.onSwipe` fires with the direction. The
   View resolves *which* `CustomAsset` was at that index and calls
   either `controller.keep(asset)` or
   `controller.markForDeletion(asset)` — translating a **gesture**
   into an **intent**, nothing more.

6. **ViewModel mutates state.**
   - `keep()` removes the asset from `pendingQueue`. Nothing else
     happens; the photo is untouched on disk.
   - `markForDeletion()` removes it from `pendingQueue` and appends it
     to `trashBuffer`. Still nothing is deleted.

7. **Trash review.**
   `TrashScreen` watches the same `swipeControllerProvider` and renders
   `trashBuffer` as a grid, with a running total in MB
   (`SwipeState.trashBufferMegabytes`). The user can restore any photo
   back into the queue (`restoreFromTrash`).

8. **Execution.**
   Tapping "Empty Trash" shows a confirmation dialog, then calls
   `SwipeController.emptyTrash()`. This is the **only method in the
   entire codebase that results in an irreversible native deletion** —
   it hands the buffered asset IDs to `GalleryService.deleteAssets`,
   which calls `PhotoManager.editor.deleteWithIds`. On iOS and Android
   11+, this itself pops a *second*, OS-level confirmation the user
   must approve.

9. **Reconciliation & recap.**
   `emptyTrash()` compares the IDs the OS confirmed deleting against
   what was requested (a user can cancel the native dialog and only
   delete some), puts any survivors back into the pending queue, sums
   the megabytes of what was actually deleted, and returns that number.
   `TrashScreen` navigates to `RecapScreen` with that figure, which
   renders the "You freed X MB!" celebration.

---

## 4. Backend Vision: Semantic Search

`data/services/semantic_search_api.dart` is the client for a planned
**Python/FastAPI backend** that lets users filter the swipe queue by
natural-language description — e.g. typing "mountain treks" and only
being shown photos from Himalayan hikes to make a keep/delete decision
about *just that category*.

### Architecture

```
Flutter App                              FastAPI Backend
────────────                             ────────────────
On-device (embedding_worker.dart):
  MobileCLIP image encoder (ONNX)
  embeds each photo thumbnail
           │
           ▼
uploadEmbedding(assetId, vector) ──────▶ FAISS index
                                          (upsert vector, keyed by
                                           asset_id — no image bytes
                                           ever sent)

semanticFilter("mountain      ┌────────────────────────┐
  treks")               ─────▶│ FastAPI embeds the query │
                               │ with MobileCLIP's TEXT   │
                               │ tower (plain PyTorch,    │
                               │ server-side — no mobile  │
                               │ constraints there),      │
                               │ then runs a FAISS        │
                               │ nearest-neighbor search   │
                               │ over the SAME space the   │
                               │ image vectors live in     │
                               └────────────┬─────────────┘
                                            ▼
                        ◀──────  ranked [{asset_id, score}, ...]
```

> **A correction worth calling out:** an earlier version of this plan
> captioned each photo and embedded the caption with SentenceTransformers.
> That's a workable design on its own, but it stops being consistent once
> MobileCLIP enters the picture (see [section 6](#6-on-device-semantic-search-pipeline)):
> MobileCLIP's image and text encoders share ONE joint embedding space by
> construction, so a photo's MobileCLIP vector and a query's MobileCLIP
> vector are directly comparable — no captioning step needed. Mixing the
> two (MobileCLIP image vectors matched against SentenceTransformers query
> vectors) wouldn't error; it would just silently return meaningless
> similarity scores, since they're different vector spaces. `uploadAssetMetadata`
> (the caption-based path) is still in `semantic_search_api.dart` as a
> documented alternative, not deleted — but pick one path and use it
> consistently end to end.

### Why this design

- **No image bytes leave the device.** Only a 512-float vector and an
  `asset_id` are sent to the backend. This keeps payloads tiny (a few KB
  per photo) and avoids the privacy and bandwidth cost of uploading
  full-resolution photos just to index them.
- **`asset_id` is the join key.** The backend never needs to know
  anything about `photo_manager` — it just stores and searches
  embeddings keyed by an opaque string. The Flutter app maps
  `asset_id` back to a real `CustomAsset`/`AssetEntity` locally.
- **Fail-soft by design.** `semanticFilter()` catches all
  network/parsing errors and returns an empty list rather than
  throwing, so the app works perfectly well with semantic search
  *disabled* — this backend is an enhancement, not a dependency, for
  the core keep/delete loop. Likewise, `uploadEmbedding()`'s failures
  are swallowed by `EmbeddingIndexer` — a photo that fails to sync just
  isn't searchable yet, it never surfaces as an app error.

### What's real vs. what's still on you

The **client-side plumbing is fully wired end to end** —
`SwipeScreen`'s search bar, `SwipeController.applySemanticFilter`, and
`SemanticSearchApi.semanticFilter` all talk to each other correctly, and
so does the upload side (`EmbeddingIndexer` → `uploadEmbedding`). What's
still a stub is the **server itself**: `SemanticSearchApi`'s `baseUrl`
points at a placeholder, so both calls fail soft until a real FastAPI +
FAISS service exists. To go live:

1. Stand up a FastAPI service exposing `POST /v1/embeddings/upsert_vector`
   (accepts `{asset_id, embedding}`, upserts into a FAISS index) and
   `GET /v1/search?q=...&top_k=...` (embeds the query with MobileCLIP's
   text tower — see the snippet at the bottom of `export_mobileclip_onnx.py`
   — and returns FAISS's nearest neighbors).
2. Point `SemanticSearchApi(baseUrl: '...')` at that deployment (wire it
   through `semanticSearchApiProvider` in `swipe_provider.dart`).
3. Everything else — the search bar, the filtering, the "no matches"
   empty state, restoring the queue on clear, the background upload —
   already works.

See [section 6](#6-on-device-semantic-search-pipeline) for the
complementary **on-device** half: how photos get embedded in the
background *before* a user ever types a query.

---

## 5. Robustness: Empty States & the Review-Again Loop

A swipe-based UI has three "edges" that are easy to get wrong: nothing
to show at all, running out of things to show, and wanting to see
something again. `SwipeState` now models all three explicitly, as
booleans/getters rather than the UI inferring them from list emptiness
alone — which is what made the earlier "just check if the queue is
empty" approach fragile.

### Telling "empty library" apart from "all caught up"

| State | Meaning | UI shown |
|---|---|---|
| `isLibraryEmpty` | The device gallery has **zero photos**, confirmed by a genuinely empty first page from `GalleryService.fetchBatch(0)` | `_EmptyLibraryView` — "No photos found", with a **Recheck Gallery** button |
| `isQueueExhausted` | The queue was non-empty at some point but has now been **fully swiped through** (`pendingQueue` empty, `hasMore` false, nothing loading, and the library was never empty) | `_AllCaughtUpView` — "All Caught Up!", with **Review Kept Photos** / **Check for New Photos** / **Go to Trash** |

Both are computed as getters on `SwipeState` rather than duplicated
`if` logic scattered through `SwipeScreen` — the View just asks
`swipeState.isLibraryEmpty` / `swipeState.isQueueExhausted` and renders
accordingly. This is the same principle as the rest of the
architecture: a boolean the ViewModel derives once, not a judgment call
the View makes from raw data.

### Recovering from an empty library

`GalleryService.invalidateCache()` clears the cached "All Photos" album
handle, and `SwipeController.refreshLibrary()` resets the whole
`SwipeState` back to its initial shape and re-runs `_initialize()`.
Together, these let the "Recheck Gallery" button genuinely re-scan the
device — covering the case where a user granted permission or added
photos *after* the app's first, empty-handed launch — rather than being
stuck showing a stale "no photos" screen for the rest of the session.

### The Review-Again loop

Every photo swiped right is now appended to `SwipeState.keptHistory` (in
addition to being removed from `pendingQueue`), via `SwipeController.
keep()`. This is a plain running list — no persistence, no extra native
calls — so it costs nothing on the happy path but gives the "All Caught
Up!" screen something to offer a second look at.

`SwipeController.reviewKeptPhotos()`:

1. Moves everything in `keptHistory` into a **fresh** `pendingQueue`.
2. Clears `keptHistory` back to empty.
3. Sets `isReviewMode = true`.
4. Sets `hasMore = false`, so `loadNextBatch()` won't try to pull *new*
   photos from the device gallery mid-review — a review pass is scoped
   to exactly the photos you already decided to keep.

Because `keep()` still appends to `keptHistory` even while
`isReviewMode` is true, swiping right during a review pass simply
re-queues that photo for a *third* pass later — the loop is naturally
repeatable, not a one-shot special case. `SwipeScreen` gives the
`CardSwiper` a `key` derived from `isReviewMode` so the swiper's
internal index state resets cleanly when the underlying data source
(fresh batches vs. `keptHistory`) changes identity.

`SwipeController.canReviewKeptPhotos` is a simple getter
(`keptHistory.isNotEmpty`) the View checks before showing the "Review
Kept Photos" button at all — no point offering a second pass over zero
photos.

---

## 6. On-Device Semantic Search Pipeline

Section 4 covered the **remote** half of semantic search — a FastAPI
backend running a FAISS index. This section covers the **on-device**
half: how photos get turned into searchable vectors *before* the user
ever types a query, without ever making the swipe UI feel laggy. It's a
three-part pipeline: a Python export script, a Dart persistent-isolate
worker, and the `EmbeddingIndexer` that throttles it against swipe
activity.

### Part 1 — exporting the model (`scripts/export_mobileclip_onnx.py`)

This is real, runnable Python — but it has to run on **your machine**,
not inside this repo's own tooling, because it needs to download Apple's
released MobileCLIP weights, which live behind hosts this environment
can't reach. The short version:

```bash
git clone https://github.com/apple/ml-mobileclip.git
cd ml-mobileclip
conda create -n mobileclip-export python=3.10 -y && conda activate mobileclip-export
pip install -e .
pip install -r ../storage_swipe/scripts/requirements.txt
source get_pretrained_models.sh   # downloads checkpoints/mobileclip_s0.pt

python ../storage_swipe/scripts/export_mobileclip_onnx.py \
  --model-name mobileclip_s0 \
  --checkpoint checkpoints/mobileclip_s0.pt \
  --output-dir ../storage_swipe/assets/models
```

What the script actually does — and why each step is there:

- **Reparameterizes the model first** (`reparameterize_model`).
  MobileCLIP's blocks use a "MobileOne"-style design with extra
  training-time branches that must be algebraically folded into a
  single branch before export, or you ship a needlessly branchy,
  slower graph.
- **Wraps `encode_image` + L2-normalization** into one traced module, so
  the ONNX graph's output is *exactly* what the Dart side needs — no
  further math required after `session.run()`.
- **Reads the checkpoint's real preprocessing constants** (input
  resolution, normalization mean/std) from its `preprocess` transform
  instead of hardcoding them. This matters more than it sounds: several
  MobileCLIP variants (S0/S1/S2/B) bake normalization into the model and
  expect raw `[0,1]`-scaled pixels; others expect standard CLIP
  normalization. Get this wrong and the model still runs — it just
  returns embeddings that don't mean anything. The script prints the
  three values it found; **copy them into `kMobileClipInputSize`,
  `kMobileClipMean`, `kMobileClipStd`** in `embedding_worker.dart`
  rather than trusting the placeholders already there.
- **Verifies PyTorch vs. ONNX output numerically** before declaring
  success (a real `numpy` comparison, not a smoke test that just checks
  the export didn't crash).
- **Converts to FP16** as the default shipped format — roughly half the
  size of FP32 with negligible accuracy loss for this architecture, and
  no calibration data required (unlike INT8).
- **Only exports the image encoder.** MobileCLIP's image and text towers
  share one embedding space, and only the image side needs to run
  on-device thousands of times; the text side (used once per typed
  query) runs server-side in plain PyTorch — see the snippet at the
  bottom of the script.

A stub for **static INT8 quantization** (the quantization mode that
actually shrinks convolutions, unlike dynamic quantization) is included
too, deliberately left for you to fill in with your own calibration
photos — calibrating on unrepresentative images can make accuracy worse
than not quantizing, so this isn't something worth faking with random
data.

### Part 2 — running it on-device (`lib/data/services/embedding_worker.dart`)

The Dart side uses [`flutter_onnxruntime`](https://pub.dev/packages/flutter_onnxruntime)
and is built around one specific, easy-to-get-wrong requirement:
**the model has to load once, not once per photo.**

An earlier version of this file used `compute()` to run inference on a
background isolate — a reasonable first instinct, but wrong for this
job: `compute()` spawns a brand-new isolate (and would reload the model
from the asset bundle) for *every single call*, which is far too slow
to run across a 50-photo batch. `OnDeviceEmbedder` instead:

1. Spawns **one** long-lived isolate via `Isolate.spawn` and keeps it
   alive for the app's lifetime.
2. Calls `BackgroundIsolateBinaryMessenger.ensureInitialized(rootIsolateToken)`
   as the very first thing inside that isolate. This is not optional —
   without it, plugin calls from a non-root isolate (including loading
   a bundled asset via `createSessionFromAsset`) silently hang or throw.
   `RootIsolateToken.instance` can only be read on the **main** isolate,
   which is why it's captured in `start()` and handed to the spawned
   isolate as part of its startup message.
3. Loads the ONNX session **once**, right after startup, then answers a
   stream of `_EmbedRequest`/`_EmbedResult` messages over a persistent
   `SendPort`/`ReceivePort` pair for as long as the app runs.
4. Does the actual image preprocessing (JPEG decode → resize → CHW
   Float32 normalization, via `_preprocess`) **inside** the worker
   isolate too, so only raw JPEG bytes cross the isolate boundary going
   in, and a `List<double>` embedding comes back out — the main isolate
   never touches image bytes for this.

`EmbeddingIndexer` sits on top of `OnDeviceEmbedder` and keeps the exact
same throttling design as before: `SwipeController` tracks whether the
user is actively swiping via a short debounce timer and passes that in
as `isUserActivelySwiping`, so indexing backs off during a swipe gesture
and resumes the moment the user pauses to look at a card.

### What I could verify from here, and what I couldn't

Being direct about the limits of this: I wrote and reasoned through this
code carefully, and the `flutter_onnxruntime` API calls and the
`BackgroundIsolateBinaryMessenger` pattern above are real, current
Flutter/package APIs — but this environment has no Android/iOS device or
emulator, and no access to the hosts that serve MobileCLIP's weights, so
none of the following has been tested end-to-end:

- That the exported ONNX graph runs correctly through
  `flutter_onnxruntime` specifically (vs. just `onnxruntime`'s Python
  bindings, which the export script's own sanity check uses).
- Real on-device latency and battery cost — the "15–30 ms per photo on
  an NPU" figure is MobileCLIP's published benchmark, not something
  measured against this integration.
- That `flutter_onnxruntime` picks up an NPU/GPU execution provider
  automatically on your target devices, vs. falling back to CPU (check
  its docs' "Implementation Status" table for your platform before
  assuming NPU acceleration is happening).

Treat the first real test run — with your actual exported model, on an
actual device — as part of the implementation work, not a formality.

---

## 7. Project Structure

```
storage_swipe/
├── scripts/
│   ├── export_mobileclip_onnx.py   # Run this yourself — see section 6
│   └── requirements.txt
├── assets/
│   └── models/                     # Drop your exported .onnx file here
└── lib/
    ├── main.dart                       # App entrypoint — ProviderScope + MaterialApp
    ├── core/
    │   ├── theme.dart                  # Colors, ThemeData — zero app logic
    │   └── permissions_service.dart    # Wraps native permission requests
    ├── data/
    │   ├── models/
    │   │   └── custom_asset.dart       # The Model: AssetEntity + byte size
    │   └── services/
    │       ├── gallery_service.dart    # Pagination + native deletion
    │       ├── semantic_search_api.dart# FAISS backend client
    │       └── embedding_worker.dart   # On-device MobileCLIP/ONNX embedder
    ├── state/
    │   └── swipe_provider.dart         # The ViewModel: SwipeState + SwipeController
    └── ui/
        ├── screens/
        │   ├── swipe_screen.dart       # Main swipe loop + search bar
        │   ├── trash_screen.dart       # Review buffer, trigger real deletion
        │   └── recap_screen.dart       # "You freed X MB!" celebration
        └── widgets/
            ├── photo_card.dart         # Presentational card face
            └── action_buttons.dart     # Keep/Delete/Undo buttons
```

---

## 8. Getting Started

```bash
flutter pub get
flutter run
```

### Platform setup you'll still need to do

- **iOS** (`ios/Runner/Info.plist`): add
  `NSPhotoLibraryUsageDescription` (and
  `NSPhotoLibraryAddUsageDescription` if you later add a "save"
  feature) with a user-facing explanation string.
- **Android** (`android/app/src/main/AndroidManifest.xml`): add
  `READ_MEDIA_IMAGES` (API 33+) and/or `READ_EXTERNAL_STORAGE` for
  older targets. `photo_manager`'s own README documents the exact
  manifest snippet and `minSdkVersion` requirements — check it before
  your first release build.
- **The on-device model is optional at runtime.** The app runs fine
  with `assets/models/` empty — `OnDeviceEmbedder.start()` will fail
  once, `EmbeddingIndexer` swallows that failure per-photo, and semantic
  search simply always returns "no matches" until you've run
  `scripts/export_mobileclip_onnx.py` and dropped the resulting `.onnx`
  file in place (see section 6). The commented-out `assets:` entry in
  `pubspec.yaml` needs uncommenting once that file exists.

---

## 9. Key Design Decisions & Trade-offs

- **Why batches of 50, sorted client-side by file size?**
  `photo_manager`/the native MediaStore/Photos APIs don't expose a
  "sort by file size" query option, since byte size isn't an indexed
  media attribute on either platform. We fetch a page of assets first
  (cheap metadata call), then resolve each one's real file size and
  sort in Dart. This means the "largest first" ordering only applies
  *within* a page of 50, not globally across the whole library — a
  deliberate trade-off to avoid statting every photo in a user's
  library up front, which would be slow and memory-heavy for large
  libraries.

- **Why `flutter_card_swiper`'s controller instead of manual
  `Draggable`/`GestureDetector` widgets?**
  It gives us fling physics, direction detection, and a
  programmatic `swipe()` API for free — which is what lets our
  `ActionButtons` trigger a *real* animated swipe (keeping the visual
  and the state change perfectly in sync) instead of faking the
  result of a swipe.

- **Why is deletion reconciled against the OS's confirmed IDs instead
  of assumed to always succeed?**
  Both iOS and Android 11+ show their own native confirmation dialog
  the instant `deleteWithIds` is called, which the user can cancel.
  If we optimistically cleared the whole trash buffer regardless of
  that outcome, a cancelled deletion would silently "lose" photos from
  the app's state (they'd vanish from view while still existing on
  disk, undiscoverable until the app restarted and re-scanned the
  library).
