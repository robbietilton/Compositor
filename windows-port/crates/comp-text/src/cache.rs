//! Bounded caches for shaped runs and laid-out paragraphs.
//!
//! Typing is the case that matters: a keystroke changes one paragraph, and everything else should be
//! reused rather than shaped and wrapped again. Both caches are bounded, and a full cache evicts in
//! one batch rather than a scan per insert, so a long document cannot grow them without limit and a
//! miss does not cost the whole cache.

use std::collections::HashMap;
use std::hash::Hash;
use std::sync::Arc;

/// What a cache has been doing, for a GUI's diagnostics or for a benchmark.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct CacheStats {
    pub hits: u64,
    pub misses: u64,
    /// Entries held now, which an empty cache reports as zero however it was configured.
    pub entries: usize,
    pub capacity: usize,
    /// Eviction rounds, not the number of entries dropped.
    pub evictions: u64,
}

impl CacheStats {
    /// How often the cache was asked for something.
    pub fn lookups(&self) -> u64 {
        self.hits + self.misses
    }

    /// The share of lookups the cache answered, and zero when it was never asked.
    pub fn hit_rate(&self) -> f64 {
        let lookups = self.lookups();
        if lookups == 0 {
            0.0
        } else {
            self.hits as f64 / lookups as f64
        }
    }
}

/// A bounded cache that keeps the values most recently asked for.
#[derive(Debug)]
pub(crate) struct Cache<K, V> {
    entries: HashMap<K, (Arc<V>, u64)>,
    capacity: usize,
    clock: u64,
    stats: CacheStats,
}

impl<K: Eq + Hash + Clone, V> Cache<K, V> {
    pub fn new(capacity: usize) -> Self {
        Cache {
            entries: HashMap::new(),
            capacity,
            clock: 0,
            stats: CacheStats { entries: 0, capacity, ..CacheStats::default() },
        }
    }

    /// The value stored for a key, if it is still there, marked as the most recently used.
    pub fn get(&mut self, key: &K) -> Option<Arc<V>> {
        self.clock += 1;
        match self.entries.get_mut(key) {
            Some((value, used)) => {
                *used = self.clock;
                self.stats.hits += 1;
                Some(value.clone())
            }
            None => {
                self.stats.misses += 1;
                None
            }
        }
    }

    /// Stores a value, evicting first when the cache is full, and hands back the shared copy.
    pub fn insert(&mut self, key: K, value: V) -> Arc<V> {
        let value = Arc::new(value);
        if self.capacity == 0 {
            return value;
        }
        if self.entries.len() >= self.capacity {
            self.evict();
        }
        self.clock += 1;
        self.entries.insert(key, (value.clone(), self.clock));
        self.stats.entries = self.entries.len();
        value
    }

    /// Drops the least recently used entries. A batch keeps one miss from costing a scan per entry.
    fn evict(&mut self) {
        if self.entries.is_empty() {
            return;
        }
        let mut stamps: Vec<u64> = self.entries.values().map(|(_, used)| *used).collect();
        stamps.sort_unstable();
        let cutoff = stamps[stamps.len() / 8];
        self.entries.retain(|_, (_, used)| *used > cutoff);
        self.stats.evictions += 1;
        self.stats.entries = self.entries.len();
    }

    pub fn clear(&mut self) {
        self.entries.clear();
        self.stats.entries = 0;
    }

    /// Bounds the cache again, dropping entries when the new bound is smaller. The counters stay:
    /// they describe what the cache has done, not what it holds.
    pub fn set_capacity(&mut self, capacity: usize) {
        self.capacity = capacity;
        self.stats.capacity = capacity;
        while self.entries.len() > capacity {
            let before = self.entries.len();
            self.evict();
            if self.entries.len() >= before {
                // The batch kept everything (capacity zero, or one entry left); drop the rest.
                self.entries.clear();
                self.stats.entries = 0;
            }
        }
        self.stats.entries = self.entries.len();
    }

    pub fn stats(&self) -> CacheStats {
        CacheStats { entries: self.entries.len(), capacity: self.capacity, ..self.stats }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_hit_hands_back_the_same_value() {
        let mut cache: Cache<u32, String> = Cache::new(4);
        cache.insert(1, "one".to_string());
        let first = cache.get(&1).unwrap();
        let second = cache.get(&1).unwrap();
        assert!(Arc::ptr_eq(&first, &second));
        assert_eq!(&*first, "one");
    }

    #[test]
    fn hits_and_misses_are_counted() {
        let mut cache: Cache<u32, u32> = Cache::new(4);
        assert!(cache.get(&7).is_none());
        cache.insert(7, 70);
        assert_eq!(*cache.get(&7).unwrap(), 70);
        let stats = cache.stats();
        assert_eq!((stats.hits, stats.misses), (1, 1));
        assert_eq!(stats.lookups(), 2);
        assert_eq!(stats.hit_rate(), 0.5);
    }

    #[test]
    fn a_cache_that_was_never_asked_has_no_hit_rate() {
        let cache: Cache<u32, u32> = Cache::new(4);
        assert_eq!(cache.stats().hit_rate(), 0.0);
        assert_eq!(cache.stats().lookups(), 0);
    }

    #[test]
    fn the_cache_never_grows_past_its_capacity() {
        let mut cache: Cache<u32, u32> = Cache::new(16);
        for key in 0..500 {
            cache.insert(key, key);
            assert!(cache.stats().entries <= 16, "{} entries", cache.stats().entries);
        }
        assert!(cache.stats().evictions > 0);
        assert_eq!(cache.stats().capacity, 16);
    }

    #[test]
    fn eviction_drops_what_was_used_longest_ago() {
        let mut cache: Cache<u32, u32> = Cache::new(8);
        for key in 0..8 {
            cache.insert(key, key);
        }
        // Keep the second half warm, so the first half is what an eviction should drop.
        for key in 4..8 {
            cache.get(&key);
        }
        cache.insert(99, 99);
        for key in 4..8 {
            assert!(cache.get(&key).is_some(), "{key} was recently used");
        }
        assert!(cache.get(&0).is_none(), "0 was not");
    }

    #[test]
    fn a_cache_of_no_capacity_stores_nothing() {
        let mut cache: Cache<u32, u32> = Cache::new(0);
        cache.insert(1, 1);
        assert_eq!(cache.stats().entries, 0);
        assert!(cache.get(&1).is_none());
    }

    #[test]
    fn clearing_empties_the_cache_and_keeps_the_counters() {
        let mut cache: Cache<u32, u32> = Cache::new(4);
        cache.insert(1, 1);
        cache.get(&1);
        cache.clear();
        assert_eq!(cache.stats().entries, 0);
        assert_eq!(cache.stats().hits, 1);
        assert!(cache.get(&1).is_none());
    }

    #[test]
    fn shrinking_the_capacity_drops_what_no_longer_fits() {
        let mut cache: Cache<u32, u32> = Cache::new(32);
        for key in 0..32 {
            cache.insert(key, key);
        }
        cache.set_capacity(4);
        assert!(cache.stats().entries <= 4, "{} entries", cache.stats().entries);
        assert_eq!(cache.stats().capacity, 4);
    }
}
