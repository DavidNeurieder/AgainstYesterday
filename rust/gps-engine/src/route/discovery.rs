// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

//! Route discovery: cluster recording after recording into routes.
//!
//! ```text
//! Track A ─┐
//! Track B ─┼→ Route 1
//! Track C ─┘
//! Track D ─→ Route 2
//! ```
//!
//! Each new track is compared against the existing [`DiscoveredRoute`]
//! representatives with [`super::matching`]; a sufficiently similar track
//! joins the first matching cluster, otherwise it seeds a new one. The
//! clustering is deliberately simple (linear scan, deterministic) — the
//! specifications recommend starting understandably and optimizing later.

use crate::Track;
use crate::route::matching::{MatchConfig, MatchScore, compare_either_direction};

/// The outcome of adding one track to a [`RouteCatalog`].
#[derive(Debug, Clone, PartialEq)]
pub struct TrackAddition {
    /// Index of the route the track joined (or that was created).
    pub route_id: usize,
    /// Whether this addition created a brand-new route.
    pub is_new: bool,
    /// The comparison score for the matched route, if it joined an existing
    /// cluster (`None` when a new route was created).
    pub matched: Option<MatchScore>,
}

/// A cluster of recordings that represent the same route.
#[derive(Debug, Clone, PartialEq)]
pub struct DiscoveredRoute {
    /// Stable index within the catalog (`route_id` from [`TrackAddition`]).
    pub id: usize,
    representative: Track,
    /// Number of recordings that have joined this cluster.
    pub track_count: usize,
}

impl DiscoveredRoute {
    /// The representative recording, currently the longest that has joined.
    pub fn representative(&self) -> &Track {
        &self.representative
    }
}

/// An incremental catalog of discovered routes.
///
/// Deterministic: the same sequence of tracks yields the same cluster
/// assignments. Tracks are compared as given — clean them
/// (filter/simplify/resample) before adding.
#[derive(Debug, Clone, PartialEq)]
pub struct RouteCatalog {
    config: MatchConfig,
    routes: Vec<DiscoveredRoute>,
}

impl Default for RouteCatalog {
    fn default() -> Self {
        Self::new(MatchConfig::default())
    }
}

impl RouteCatalog {
    /// Starts an empty catalog with the given matching thresholds.
    pub fn new(config: MatchConfig) -> Self {
        Self {
            config,
            routes: Vec::new(),
        }
    }

    /// Adds one track, joining the best matching cluster or seeding a new one.
    pub fn add_track(&mut self, track: &Track) -> TrackAddition {
        let mut best: Option<(usize, MatchScore)> = None;

        for (idx, route) in self.routes.iter().enumerate() {
            let matched = compare_either_direction(track, route.representative(), &self.config);
            let Some(score) = matched else {
                continue;
            };
            let replace = match &best {
                Some((_, current)) => score.overall_score > current.overall_score,
                None => true,
            };
            if replace {
                best = Some((idx, score));
            }
        }

        match best {
            Some((idx, score)) => {
                let route = &mut self.routes[idx];
                route.track_count += 1;
                if track.distance().meters() > route.representative.distance().meters() {
                    route.representative = track.clone();
                }
                TrackAddition {
                    route_id: idx,
                    is_new: false,
                    matched: Some(score),
                }
            }
            None => {
                let id = self.routes.len();
                self.routes.push(DiscoveredRoute {
                    id,
                    representative: track.clone(),
                    track_count: 1,
                });
                TrackAddition {
                    route_id: id,
                    is_new: true,
                    matched: None,
                }
            }
        }
    }

    /// Number of discovered routes.
    pub fn route_count(&self) -> usize {
        self.routes.len()
    }

    /// All discovered routes, in discovery order.
    pub fn routes(&self) -> &[DiscoveredRoute] {
        &self.routes
    }

    /// The representative recording of a route, if it exists.
    pub fn representative(&self, route_id: usize) -> Option<&Track> {
        self.routes.get(route_id).map(|r| r.representative())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::FilterConfig;
    use crate::SimplifyConfig;
    use crate::geo::Coordinate;
    use crate::synthetic::{SyntheticConfig, generate, reverse};

    fn route_a() -> Vec<Coordinate> {
        vec![
            Coordinate::new(52.500, 13.400).unwrap(),
            Coordinate::new(52.506, 13.403).unwrap(),
            Coordinate::new(52.512, 13.401).unwrap(),
            Coordinate::new(52.518, 13.408).unwrap(),
        ]
    }

    fn route_b() -> Vec<Coordinate> {
        vec![
            Coordinate::new(52.510, 13.410).unwrap(),
            Coordinate::new(52.505, 13.430).unwrap(),
            Coordinate::new(52.498, 13.455).unwrap(),
        ]
    }

    fn cleaned(track: &Track) -> Track {
        let (filtered, _report) = track.filter(&FilterConfig::default());
        let simplified = filtered.simplify(&SimplifyConfig::default());
        simplified
            .resample_by_distance(crate::units::Distance::from_meters(25.0))
            .unwrap()
    }

    fn record(route: &[Coordinate], seed: u64, noise: f64) -> Track {
        cleaned(&generate(route, &SyntheticConfig::noisy(seed, noise)))
    }

    /// A catalog whose tolerance is loose enough to absorb GPS noise but
    /// strict enough that the two synthetic routes don't merge.
    fn catalog() -> RouteCatalog {
        RouteCatalog::new(MatchConfig {
            lateral_tolerance: crate::units::Distance::from_meters(30.0),
            min_spatial_overlap: 0.5,
            ..MatchConfig::default()
        })
    }

    #[test]
    fn same_route_recordings_cluster_together() {
        let mut catalog = catalog();
        let first = catalog.add_track(&record(&route_a(), 1, 0.0));
        assert!(first.is_new);
        assert_eq!(first.route_id, 0);

        let joined = catalog.add_track(&record(&route_a(), 99, 8.0));
        assert!(
            !joined.is_new,
            "another take on the same route joins the cluster"
        );
        assert_eq!(joined.route_id, 0);
        assert!(joined.matched.is_some());

        assert_eq!(catalog.route_count(), 1);
        assert_eq!(catalog.routes()[0].track_count, 2);
    }

    #[test]
    fn different_route_creates_new_cluster() {
        let mut catalog = catalog();
        let a = catalog.add_track(&record(&route_a(), 1, 0.0));
        assert_eq!(a.route_id, 0);

        let b = catalog.add_track(&record(&route_b(), 2, 0.0));
        assert!(b.is_new, "unrelated route must not join route A");
        assert_eq!(b.route_id, 1);
        assert_eq!(catalog.route_count(), 2);
    }

    #[test]
    fn reversed_recording_joins_the_same_route() {
        let mut catalog = catalog();
        catalog.add_track(&record(&route_a(), 1, 0.0));

        let track = reverse(&record(&route_a(), 7, 6.0));
        let joined = catalog.add_track(&track);
        assert!(!joined.is_new, "a reversed run is still the same route");
        assert_eq!(joined.route_id, 0);
    }

    #[test]
    fn representative_is_the_longest_recording() {
        let mut catalog = catalog();
        let short = record(&route_a(), 1, 0.0);
        // A longer (sparser) recording of the same route must win the rep.
        let long = record(&route_a(), 2, 0.0);
        catalog.add_track(&short);
        catalog.add_track(&long);

        let rep = catalog.representative(0).unwrap();
        assert!(rep.distance().meters() >= long.distance().meters());
    }

    #[test]
    fn deterministic_for_same_input_sequence() {
        let feed = |c: &mut RouteCatalog| {
            c.add_track(&record(&route_a(), 1, 4.0));
            c.add_track(&record(&route_a(), 2, 4.0));
            c.add_track(&record(&route_b(), 3, 0.0));
            c.add_track(&record(&route_a(), 4, 8.0));
        };

        let mut x = RouteCatalog::new(catalog().config);
        let mut y = RouteCatalog::new(catalog().config);
        feed(&mut x);
        feed(&mut y);

        assert_eq!(x.routes(), y.routes());
        assert_eq!(
            x.route_count(),
            2,
            "3 takes on A and 1 on B cluster into two routes"
        );
    }
}
