# Route statistics specification (S0)

Status: draft baseline for S1–S4 implementation (2026-11-16, `improve_app`).  
Goal: make route statistics reproducible, deterministic, engine-owned, and honest about missing/low-quality data.

## 1. Current ownership and data flow

### Source data (persisted, authoritative)
- **Routes** (`RouteRepository`, `engine/models.dart` `Route`): `id`, `name`, `distance`, `geometry`, `attemptCount` (seed/fallback), `personalBest`, `isExample`, etc.
- **Activities/attempts** (`ActivityRepository`, `Activity`): `id`, optional `routeId`, `startedAt`, `duration` (elapsed/moving seconds as stored today), `distance`, `track` (processed points), `rawFixes`, `isExample`.
- Derived route aggregates must remain recomputable from persisted routes + activities (and engine analysis of their tracks). No cached aggregate is a source of truth.

### Engine boundary (must own math)
- `EngineService.computeRouteStats({route, attempts}) -> RouteStats`  
  - Rust: `analytics::RouteStats::compute` (`rust/gps-engine/src/analytics.rs`), exposed via capi `gps_route_stats`.  
  - Dart: `RustEngineService.computeRouteStats`, `FakeEngineService.computeRouteStats`.
- `EngineService.computePaceAnalysis({activity, route, trackMeters}) -> PaceAnalysis`  
  - Rust/capi `gps_pace_analysis`; Dart/fake parity.
- `EngineService.compareRouteSegments(...)`, `createAttempt(...)`, `analyzeTrack(...)`, `routeInfo(...)` provide segment/track primitives used by stats and comparisons.

### Flutter aggregation/presentation (current)
- `routeStatsIndexProvider` (`features/routes/application/route_stats_provider.dart`): for each route, selects activities where `a.routeId == route.id && a.duration != null`, calls `engine.computeRouteStats`, caches by route id (reactive to repo changes).
- `fallbackRouteStats` (`route_stats.dart`): synchronous fallback from seeded `route.personalBest`/`attemptCount`.
- UI: `RouteStatisticsScreen` / section pages (`route_statistics_screen.dart`), `RouteStatsView`, `PbProgressionSection`, `SegmentComparisonSection`, `HeadToHeadSection`, performance chart.
- Global/history helpers: `computeHistoryPb` (`history_grouping.dart`), result ranking `_rank` in `result_screen.dart`.

## 2. Canonical metric definitions

| Metric | Definition (canonical) | Notes |
| --- | --- | --- |
| Elapsed time | Wall time span of the recording/attempt | Keep distinct from moving time; stored as `Activity.duration` today (confirm semantics per context). |
| Moving time | Time spent moving (engine/recorder motion-gated) | Use for pace/PB comparisons where the app defines performance by moving effort; must be labeled/defined consistently. |
| Distance | Along-track/route distance in meters from engine/track processing (route coverage on-route, filtered geodesic for free-run/live where applicable) | Do not recompute with ad-hoc haversine in Dart for authoritative stats except display fallbacks. |
| Pace | Time per distance (e.g. s/km, min/km) | **Never average per-attempt paces arithmetically.** Derive from aggregate time and aggregate distance (or from a defined best/representative attempt) and state which time basis is used. |
| Speed | Distance per time (m/s, km/h) | Derived from canonical distance/time; same aggregation rule. |
| PB | Fastest eligible attempt for the route by the canonical performance time | Ties: deterministic (e.g. earliest/latest by policy — define and test). |
| Average/median | Mean/median of eligible attempt performance times | Median preferred for robustness; report sample size. |
| Trend | `trendSecondsPerRun` as currently computed by engine (linear/defined fit over attempts) | Null when insufficient data; document exact method in engine. |
| Recent average | Mean over last N eligible attempts (currently 5) | Null when insufficient. |
| Splits/gap | `PaceAnalysis` km splits and gap-to-PB curve (100 m samples) | Relative to PB/reference attempt; empty/unavailable when no valid reference/track. |

**Null/unavailable:** a metric is `null`/unavailable when inputs are missing, insufficient, or below quality/eligibility thresholds. Missing sensor data (e.g. altitude) must never be treated as zero.

## 3. Eligibility and quality rules (target)

Statistics must distinguish performance from GPS/matching/recording artifacts.

### Attempt eligibility for route aggregates
- **Included (baseline):** `activity.routeId == route.id` and `activity.duration != null` and duration > 0 and sufficient recorded distance/track for the metric.
- **Excluded / flagged:** incomplete or degenerate attempts (zero/near-zero distance or time), attempts with insufficient GPS/track quality or coverage for reliable comparison, and any attempt explicitly marked invalid by future policy.
- **Examples/bundled routes:** `Route.isExample` / `Activity.isExample` are currently present in models; decide and document whether example/demo activities contribute to personal aggregates (recommended: exclude from personal performance stats, or label separately).
- **Comparable attempts:** for improvement/progression/segment-vs-PB, require comparable basis (same route direction/coverage policy, moving-time basis where applicable). Partial/identity-matched-but-not-full-attempt cases (per route-matching plan) must not count as full PB attempts unless policy says so.

### Deletion, import, mutation
- Deleting an activity/route must immediately remove its contribution from derived aggregates (repositories/providers are reactive today — preserve this).
- Imported/bundled data must follow the same eligibility labels; rebuilding aggregates from source must yield the same result.
- Route matching/classification may assign/change `routeId` post-run; aggregates must reflect current persisted state.

### GPS quality / elevation
- Use existing GPS quality/track analytics signals; do not promote unreliable recordings to PB/benchmark silently.
- Elevation metrics/profiles only when altitude samples are present and quality/coverage is sufficient (filtered; never raw-noise sums as truth, never zero-fill missing data).

## 4. Stored vs computed

- **Stored:** routes, activities (including `track`, `rawFixes`, metadata), and route-level seeded fields as they exist today.
- **Computed on demand (current & default):** `RouteStats`, `PaceAnalysis`, segment comparisons, progression/head-to-head views, history PB/ranks — derived by engine/providers/UI from stored data.
- **Caching (deferred, S4 only if profiled necessary):** route-keyed, schema/versioned, invalidated on mutation, fully rebuildable; never the sole source of truth.

## 5. Migration list (Dart → engine/service-owned)

Candidates to migrate or consolidate behind engine/service APIs (avoid parallel Dart math):

| Location | Current behavior | Target |
| --- | --- | --- |
| `features/routes/application/route_stats_provider.dart` / `route_stats.dart` | Selects eligible attempts per route, calls engine, fallback | Keep selection/orchestration; continue tightening eligibility/quality rules (possibly engine-side). |
| `features/routes/presentation/pb_progression.dart` | Computes PB progression events client-side from attempts | Now uses shared spec-aligned helper; future: engine/service progression data. |
| `features/routes/presentation/route_statistics_screen.dart` / sections | Assembles eligible attempts, head-to-head, charts | Keep presentation; move aggregate/progression/period computations to engine/service results. |
| `features/history/application/history_grouping.dart` `computeHistoryPb` | Global/history PB computed in Dart | Now spec-aligned for example exclusion; future: engine/service-backed computation. |
| `features/result/presentation/result_screen.dart` `_rank` | Rank computed in Dart | Now uses shared spec-aligned helper; future: engine/service-backed logic. |
| `features/recording/application/recording_controller.dart` `_forwardBearing` | Demo-only bearing helper | Non-stats, but keep isolated; do not fold into stats math. |
| Any UI pace/total derivations | Ad-hoc formatting/derivation in widgets | Use engine-provided aggregates/samples; UI formats only. |

## 6. S1+ implementation notes

- Extend `RouteStats`/`PaceAnalysis` and capi/Dart/fake in lockstep; preserve backward compatibility for persisted/wire data where applicable.
- Add explicit fields for totals/pace/improvement/elevation/quality as agreed (nullable when unavailable).
- Keep `routeStatsIndexProvider` reactive and deletion-safe; do not introduce a second stats source of truth.
- Tests: extend Rust analytics tests, fake/Rust parity, and Flutter stats/history/result tests for eligibility, units, empty/insufficient data, and mutation.

## 7. Decisions (R1, 2026-11-16)

- **Canonical performance time basis (current):** route PB, averages/median/last/fastest/slowest/range/trend/recent, progression, ranking, and pace aggregates use the stored attempt performance duration (`Activity.duration` / route-stats duration field) as recorded today (elapsed/moving semantics remain those of the persisted duration; UI must label basis when moving-time alternatives are introduced). `TrackAnalytics` keeps elapsed/moving/stopped breakdowns; future API additions may expose both bases explicitly, but existing aggregates must not silently change meaning.
- **Examples/bundled data:** `Activity.isExample` and attempts on `Route.isExample` are excluded from personal aggregates, progression, history PB, and result ranking. Bundled/demo data may be shown as demo context but never mixed into personal performance metrics.
- **Eligibility baseline (current):** an eligible route attempt has `routeId` match, is not an example, and has a non-null recorded duration. Zero-duration attempts remain representable by current engine/tests; distance/quality/coverage gates and exclusion of degenerate or insufficient-quality attempts are follow-up tightening once quality signals are wired into aggregation (must be explicit, not silent).
- **Comparable/partial attempts:** only attempts classified as valid comparable route attempts count toward PB/progression/segment-vs-PB benchmarks. Partial, ambiguous, or identity-only associations (per route-matching policy) must not count as full PB attempts unless explicitly promoted by policy; treat as excluded/unavailable until classification is exposed in stats inputs.
- **Sample size/quality thresholds:** keep trend/recent/verdict only when sufficient attempts exist (current engine behavior: trend with >=2, recent from up to 5, verdict from recent vs average). Elevation metrics/profiles require `has_elevation_data` and adequate samples/coverage; show unavailable/insufficient rather than fabricating values. Consistency claims require enough samples to be meaningful (define numeric minimums when consistency UI expands).
- **Determinism/ties:** strict improvement (`<` standing best) sets a new PB/progression event; equal times do not replace/duplicate an improver. Ranking is by fastest duration with deterministic tiebreaks.

## 8. Implementation status (2026-11-16)

- **S0/R1:** Spec and migration baseline documented with R1 decisions (`docs/route_statistics_spec.md`): recorded-duration performance basis (current), `isExample` exclusion, baseline eligibility, comparable/partial-attempt policy, sample-size/quality thresholds, and deterministic tie/progression/ranking rules.
- **S1:** `RouteStats` extended in Rust analytics/capi and Dart (models, Rust/fake engine services, UI) with total distance/time, aggregate/best pace (s/km), and first→latest improvement; route_stats FFI carries per-attempt distance. Rust/Dart parity maintained for covered fields.
- **R2:** Engine-backed `computeRouteProgression`/`computeRouteAttemptRank` added (Rust analytics/capi, FFI, `EngineService`, fake/Rust services). PB progression and result ranking use engine APIs; history screen derives PB context from engine progression and route stats. Shared Dart helpers remain for compatibility/tests but runtime UI uses engine-backed derivations.
- **R3:** Eligibility tightened explicitly to positive durations in Rust/fake/helpers/history logic and updated tests; route stats overview labels performance time basis (recorded duration, eligible attempts only). Deeper time-basis split (moving vs elapsed) and richer quality/eligibility metadata remain incremental follow-ups.
- **R4:** Segment comparison UI enhanced to surface engine-computed segment range, per-run speeds, best/avg, and spread (building on existing engine segment comparison).
- **R5:** Route overview elevation summary aggregates across multiple engine-analyzed attempts (avg ascent/descent, min/max elevation) when elevation data is available.
- **R6:** Added route comparison screen (`/routes/compare`) showing side-by-side engine-backed route statistics and metadata for two routes.
- **R7:** Added Rust regression tests for progression/rank eligibility/determinism; ran targeted parity/behavior tests after each point. Caching not introduced (on-demand, reactive computation retained; no measured justification). Broader profiling, additional engine-level segment/elevation/profile APIs, moving-vs-elapsed dual-basis fields, and route-comparison depth remain future increments.