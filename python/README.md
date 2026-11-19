# against-yesterday (Python)

Python bindings for the `gps-engine` Rust crate from [Against Yesterday](https://github.com/DavidNeurieder/AgainstYesterday).

This package is an early MVP focused on GPX I/O and core track processing.
The API may evolve while the engine is in the `0.x` series.

## Development

```bash
cd python
python -m venv .venv
source .venv/bin/activate
pip install maturin pytest
maturin develop
pytest
```

## Quick example

```python
import against_yesterday as ay

track = ay.Track.from_gpx_path("run.gpx")
print(track.point_count, track.distance_m, track.duration_s)

filtered, report = track.filter()
simple = filtered.simplify(tolerance_m=2.0)
resampled = simple.resample_by_distance(interval_m=5.0)

resampled.to_gpx_path("processed.gpx")
```

## License

AGPL-3.0-or-later, consistent with the Against Yesterday repository.
