+++
title = "Joining Events from Two Kafka Topics Without External Frameworks"
date = 2026-02-19
lastmod = 2026-02-19
tags = ["kafka", "join", "stream-processing", "distributed-systems", "rust", "rdkafka"]
draft = false
sourceHash = "b86fceccdf72e5730dd11fd6a9981cbc"
description = "Approaches to joining events from two Kafka topics without Kafka Streams, Flink, or ksqlDB — using only the consumer/producer API. Analysis of the case when the join key is in the message body and topics have different topologies."
+++

The task: join events from two Kafka topics by a common key without using Kafka Streams, Flink, ksqlDB, or other stream-processing frameworks. Only the consumer/producer API and minimal code.


## The fundamental problem: co-partitioning {#фундаментальная-проблема-co-partitioning}

Before considering approaches, we need to understand the key constraint. A Kafka consumer reads partitions, not entire topics. If two topics are partitioned differently (different partition counts or different partitioning strategies), events with the same key can end up in different partitions assigned to different consumers.

For a correct partition-local join, the following is **mandatory**:

-   Same number of partitions in both topics
-   Same partitioning strategy (the same partitioner on the same key)
-   Consumer subscribed to both corresponding partitions (manual assign or one consumer group for both topics)

If co-partitioning is violated, either repartitioning is needed (see the [corresponding section](#подход-4-repartitioning-промежуточный-топик)), or a global approach (compacted topic as a lookup table, database).

This is what Kafka Streams does automatically: it checks co-partitioning at startup and fails with a `TopologyException` on mismatch ([Confluent: How Co-Partitioning Works in Kafka Streams](https://www.confluent.io/blog/co-partitioning-in-kafka-streams/)).


## The worst case: join key in the message body, topologies don't match {#худший-случай-join-key-в-теле-сообщения-топологии-не-совпадают}

A separate case to consider is when two topics don't just have different partition counts, but **completely different topologies**: different Kafka keys, different partition counts, and the join key **is not the Kafka key in either topic** — it's in the message body (payload).


### Example {#пример}

```text
Topic A: "orders" (key=order_id, 12 partitions)
  body: { "order_id": "ORD-123", "items": [...], "payment_ref": "PAY-456" }

Topic B: "payments" (key=payment_id, 8 partitions)
  body: { "payment_id": "PAY-456", "amount": 1500, "status": "confirmed" }

Join condition: A.body.payment_ref == B.key (or B.body.payment_id)
```

The Kafka key in topic A is `order_id`, in topic B — `payment_id`. The join needs `payment_ref`, which is **in the body** of message A. Co-partitioning is impossible in principle — the keys are even semantically different.


### Why this is harder than a standard join {#почему-это-сложнее-стандартного-join}

1.  **Partition-local join is impossible** — events with the same `payment_ref` / `payment_id` are in arbitrary partitions of different topics. A consumer reading partition 0 of both topics won't see both sides of the join.
2.  **Join key must be extracted from the payload** — deserialization is required for every message before we even decide what to do with it.
3.  **Simply subscribing to both topics won't work** — even if the consumer reads all partitions of both topics, with horizontal scaling (multiple instances), each instance only sees a subset of partitions, and the join breaks apart.


### Approaches that work {#какие-подходы-работают}


#### Variant A: Repartitioning both topics {#вариант-a-repartitioning-обоих-топиков}

The most "honest" approach. Both topics are re-keyed by join key into intermediate topics with the same partition count:

```text
Topic A (key=order_id) ──► extract payment_ref from body ──► Intermediate A' (key=payment_ref, 8 partitions)
Topic B (key=payment_id) ──────────────────────────────────► (already partitioned by payment_id, 8 partitions)

If B.key == join key, repartitioning is only needed for A.
If join key is in both bodies — repartition both.

Intermediate A' + Topic B (or B') → partition-local join
```

Pros:

-   After repartitioning — standard partition-local join, scales horizontally
-   Each instance processes only its own partitions

Cons:

-   **Two additional Kafka hops** (if repartitioning both) — double latency
-   Intermediate topics take up storage
-   Need to guarantee exactly-once at the re-key stage (Kafka transactions)
-   If the join key is deeply nested in JSON / protobuf — deserialization at the repartitioning stage, then again at the join stage


#### Variant B: Global buffer (broadcast approach) {#вариант-b-глобальный-буфер--broadcast-подход}

One of the topics (the smaller one) is read **entirely** — all partitions, by every consumer instance. The join key is extracted from message bodies, building a global lookup table. The second topic is streamed normally.

```text
Topic B (payments) ──► every instance reads ALL partitions ──► Map<payment_id, Payment>
Topic A (orders)   ──► stream: extract payment_ref from body ──► lookup in Map ──► emit joined
```

Implementation: for the "global" topic use `consumer.assign()` instead of `subscribe()` — manually assign all partitions to each instance. This is exactly what `GlobalKTable` does in Kafka Streams.

Pros:

-   No repartitioning needed
-   No co-partitioning needed
-   Simple implementation

Cons:

-   **Each instance stores a full copy** of the global topic — O(N) memory where N is the full reference size
-   Not suitable if the "reference" topic is large (millions of records × kilobytes = gigabytes per instance)
-   Reference updates arrive with delay — eventual consistency


#### Variant C: Database-backed join with key extraction {#вариант-c-database-backed-join-с-извлечением-ключа}

Both consumers deserialize the payload, extract the join key, and write to a database with an index on the join key:

```sql
-- Consumer A writes:
INSERT INTO orders (order_id, payment_ref, payload, ts)
VALUES ('ORD-123', 'PAY-456', '...', now())
ON CONFLICT (order_id) DO UPDATE SET payload = EXCLUDED.payload;

-- Consumer B writes:
INSERT INTO payments (payment_id, payload, ts)
VALUES ('PAY-456', '...', now())
ON CONFLICT (payment_id) DO UPDATE SET payload = EXCLUDED.payload;

-- Join:
SELECT o.*, p.*
FROM orders o
JOIN payments p ON o.payment_ref = p.payment_id;
```

Pros:

-   Simplest to understand
-   SQL provides flexibility — any join logic, filtering, aggregation
-   Index on join key makes lookups fast
-   No repartitioning, no co-partitioning needed

Cons:

-   DB as bottleneck at high throughput
-   Exactly-once between Kafka and DB — outbox pattern or idempotent writes
-   Network latency per INSERT


#### Variant D: Request-response via intermediate topic {#вариант-d-request-response-через-промежуточный-топик}

If the join is asymmetric (stream A initiates, needs to wait for a response from stream B), correlation can be organized:

```text
Topic A (orders) ──► Consumer: extract payment_ref ──► store correlation {payment_ref → order}
                                                    ──► (optionally) request data via Topic B

Topic B (payments) ──► Consumer: receive payment ──► lookup correlation by payment_id ──► emit joined
```

This is essentially the [Correlation Identifier](https://www.enterpriseintegrationpatterns.com/patterns/messaging/CorrelationIdentifier.html) pattern from Enterprise Integration Patterns. The consumer maintains `Map<join_key, PendingRequest>` and matches incoming events from both topics by extracted join key.


### Approaches that DON'T work {#какие-подходы-не-работают}

-   **Partition-local join without repartitioning** (approaches 1 and 3 "as-is") — join key is in arbitrary partitions, partition-local state won't help
-   **Simple `subscribe()` on both topics** — when scaling, each instance sees only part of the data, the join key can be split between instances


### Summary of variants for the "join key in body" case {#сводка-по-вариантам-для-случая-join-key-в-теле}

| Variant                 | Repartitioning      | Memory per instance          | Scalability                   | Latency                   |
|-------------------------|---------------------|------------------------------|-------------------------------|---------------------------|
| **A: Repartitioning**   | Yes (1 or 2 topics) | Join state only              | Horizontal                    | +1-2 Kafka hops           |
| **B: Global buffer**    | No                  | Full copy of reference       | Vertical (RAM-bound)          | Minimal                   |
| **C: Database-backed**  | No                  | Minimal                      | Depends on DB                 | Network latency            |
| **D: Correlation ID**   | No                  | Map of pending requests      | Horizontal (with caveats)     | Depends on second topic   |

The choice depends on:

-   **Reference topic size** — fits in RAM → variant B; no → variant A or C
-   **Throughput** — high → variant A (partition-local after repartitioning); moderate → variant C
-   **Already have a DB** → variant C — minimal code
-   **Asymmetric join** (one initiates, other responds) → variant D


## Approach 1: Client-side join with in-memory store {#подход-1-client-side-join-с-in-memory-store}


### How it works {#как-работает}

The consumer subscribes to both topics (or two consumers in one process read one topic each). Incoming events are buffered in a local `HashMap<JoinKey, Event>`. When events from both topics arrive for the same key — a joined result is formed and sent out (to an output topic or a database).

```text
Topic A ──► Consumer ──┐
                       ├──► HashMap<key, (A?, B?)> ──► emit joined
Topic B ──► Consumer ──┘
```


### Buffering variants {#варианты-буферизации}


#### Infinite buffer (unbounded join) {#infinite-buffer--unbounded-join}

All events are stored in memory until their pair arrives. Suitable for cases when both sides are **guaranteed** to arrive and data doesn't grow infinitely (e.g., request-response pattern).

Problems:

-   Memory leak if one side never arrives (orphan events)
-   No TTL — buffer grows unboundedly on event loss


#### Windowed join (time-bounded buffer) {#windowed-join--time-bounded-buffer}

The buffer is limited by a time window. An event from topic A waits for its pair from topic B within the window (e.g., 5 minutes). If the pair doesn't arrive — the event is dropped or sent to a dead letter topic.

```text
window = [event.timestamp - before, event.timestamp + after]
```

This is the analog of `JoinWindows` from Kafka Streams ([JoinWindows javadoc](https://kafka.apache.org/31/javadoc/org/apache/kafka/streams/kstream/JoinWindows.html)), but implemented manually.

Key decisions:

-   **Which time for the window?** Event time (timestamp from the message) vs. processing time (wall clock). Event time is more correct but requires handling out-of-order events.
-   **Window size** — trade-off: large window = more memory but catches late events; small window = less memory but loses late arrivals.
-   **Eviction policy** — by timer, by watermark, or by element count.


### Delivery semantics {#семантики-доставки}

**At-least-once**: commit offset after emitting the joined result. On restart, some events will be re-read and may be re-joined (duplicates). The handler must be idempotent.

**Exactly-once**: use Kafka transactions — read from both topics, form the joined result, write to the output topic, and commit offsets **atomically** in one transaction ([Confluent: Transactions in Apache Kafka](https://www.confluent.io/blog/transactions-apache-kafka/)).

```text
producer.beginTransaction()
producer.send(joined_record)
producer.sendOffsetsToTransaction(offsets, consumerGroupId)
producer.commitTransaction()
```


### Recovery on restart {#восстановление-при-рестарте}

The main problem: in-memory state is **lost** on restart. Options:

1.  **Re-read both topics from the beginning** — if topics are small or retention allows. Slow but simple approach.
2.  **Store state in a changelog topic** — before each buffer change, write a record to a compacted topic. On restart — restore state from the changelog. This is exactly what Kafka Streams does with RocksDB + changelog ([Kafka Streams Internal Data Management](https://cwiki.apache.org/confluence/display/KAFKA/Kafka+Streams+Internal+Data+Management)).
3.  **Periodic snapshots** — periodically serialize the buffer to disk. On restart — load the snapshot + read remaining offsets.


### Rebalancing {#rebalancing}

During rebalance (adding/removing a consumer), partitions are reassigned. Local state for lost partitions is no longer needed, and for new ones — it hasn't been built yet.

Solutions:

-   **CooperativeStickyAssignor** — minimizes partition reassignment, preserving state ([Confluent: Cooperative Rebalancing](https://www.confluent.io/blog/cooperative-rebalancing-in-kafka-streams-consumer-ksqldb/))
-   **Static group membership** (`group.instance.id`) — consumer doesn't trigger rebalance during short restarts
-   On `onPartitionsRevoked` — clear state for revoked partitions; on `onPartitionsAssigned` — rebuild state for new ones


### When to use {#когда-использовать}

-   Both topics with low throughput and events don't accumulate for long
-   Join by event time with a predictable window (request receives response within N seconds)
-   State loss on restart is acceptable (or there's a changelog)
-   Simplicity matters more than reliability


## Approach 2: Compacted topic as a lookup table {#подход-2-compacted-topic-как-lookup-table}


### How it works {#как-работает}

One of the topics is a reference (dimensions/reference data), configured with `cleanup.policy=compact`. The consumer reads this topic **from the beginning** entirely at startup, building a local `HashMap<key, value>`. Then it stream-reads the second (event) topic and does a lookup in the HashMap for each event.

```text
Compacted topic (users) ──► bootstrap: load all → HashMap<userId, User>
Event topic (orders)    ──► stream: for each order → lookup user → emit enriched
```

This is a manual implementation of the `GlobalKTable` pattern from Kafka Streams ([Confluent: Kafka Streams Concepts](https://docs.confluent.io/platform/current/streams/concepts.html)).


### Reference updates {#обновления-справочника}

Two consumers:

1.  **Dimension consumer** — listens to the compacted topic, updates the HashMap on new records
2.  **Event consumer** — reads the event stream, does lookups

Order matters: the dimension consumer must be ahead of the event consumer, otherwise lookups may return stale data or `null` for fresh keys.


### Semantics {#семантики}

**At-least-once** for the event stream: standard commit-after-process.

For the dimension topic, the semantics is usually eventual consistency — the reference may lag by a few messages, and the join will return slightly outdated data. For most use cases (enriching orders with user data) this is acceptable.


### Recovery on restart {#восстановление-при-рестарте}

The dimension consumer re-reads the compacted topic with `auto.offset.reset=earliest`. Kafka log compaction guarantees that at least the last value for each key is stored ([Confluent: Log Compaction](https://docs.confluent.io/kafka/design/log_compaction.html)).

Recovery time depends on the reference size. For millions of records, bootstrap can take minutes.

Optimization: snapshot the HashMap to disk + remember the offset. On restart, load the snapshot and read only new records.


### Memory {#память}

The entire reference lives in heap. Estimate: if the compacted topic has 10M records at ~1 KB = ~10 GB RAM. For large references — use an [embedded store](#подход-3-embedded-state-store--rocksdb-badgerdb-sqlite) or an [external DB](#подход-5-database-backed-join).


### Gotchas {#gotchas}

-   **Compaction is not instant** — Kafka runs compaction in the background. The consumer may see multiple versions of one key during bootstrap. HashMap overwrites the value — this is correct, but worth knowing.
-   **Tombstone records** (`value=null`) — mean deletion. The consumer must remove the entry from the HashMap on receiving a tombstone.
-   **No co-partitioning requirement** — the dimension topic is read entirely, the join is not partition-local. This is the main advantage over approach 1.
-   **Cold start** — first startup is slow: the entire reference must be read before event processing begins.


### When to use {#когда-использовать}

-   One of the topics is a relatively static reference (users, products, configs)
-   The reference fits in memory (or in an embedded DB)
-   No bidirectional join (stream-stream) needed, only enrichment
-   Eventual consistency of the reference is acceptable


## Approach 3: Embedded state store (RocksDB, BadgerDB, SQLite) {#подход-3-embedded-state-store--rocksdb-badgerdb-sqlite}


### How it works {#как-работает}

Instead of an in-memory `HashMap`, an embedded key-value DB is used. The principle is the same as in approaches 1 and 2, but state is stored on disk and survives restarts.

```text
Topic A ──► Consumer ──┐
                       ├──► RocksDB/BadgerDB ──► emit joined
Topic B ──► Consumer ──┘
```

This is exactly what Kafka Streams does under the hood: RocksDB as the default state store + changelog topic for recovery on disk loss ([Confluent: Performance Tuning RocksDB for Kafka Streams](https://www.confluent.io/blog/how-to-tune-rocksdb-kafka-streams-state-stores-performance/)).


### Choosing an embedded store {#выбор-embedded-store}

| Store        | Language                          | Features                                                   |
|--------------|-----------------------------------|------------------------------------------------------------|
| **RocksDB**  | C++ (bindings for Java, Go, Rust) | Kafka Streams standard, LSM-tree, high write throughput    |
| **BadgerDB** | Go                                | LSM-tree, native Go, ACID transactions                     |
| **SQLite**   | C (bindings everywhere)           | SQL interface, easier for complex joins                    |
| **Pebble**   | Go                                | RocksDB-compatible, used in CockroachDB                    |
| **LMDB**     | C                                 | B-tree, fast reads, zero-copy                              |


### Semantics {#семантики}

**At-least-once**: write to the store, then commit offset. On restart — state is already on disk, re-processed messages overwrite the same keys (idempotent).

**Exactly-once**: write to the store + write offset **to the same store** (not to Kafka's `__consumer_offsets`). Manual offset management via `consumer.seek()` at startup. Atomicity is ensured by the store's transaction.


### Recovery on restart {#восстановление-при-рестарте}

State is already on disk — **instant restart**. This is the main advantage over the in-memory approach.

For protection against disk loss:

-   **Changelog topic** — write each state change to a compacted topic. On disk loss — restore the store from the changelog.
-   **Backup/replication** — if the store supports it (e.g., LMDB snapshots).


### Gotchas {#gotchas}

-   **Disk binding** — state is local to a specific instance. On rebalance (partition moves to another instance), state needs to be rebuilt. Kafka Streams solves this via standby replicas (`num.standby.replicas`).
-   **Disk IOPS** — RocksDB generates write amplification due to LSM compaction. Fine on SSDs, problematic on HDDs.
-   **GC pressure** — for JVM applications: RocksDB via JNI doesn't create GC pressure (data is off-heap). BadgerDB in Go — also fine. SQLite via JDBC — depends on result sizes.
-   **Disk size** — LSM-tree stores (RocksDB, BadgerDB) can use 2--10x more disk than the logical data size due to compaction.


### When to use {#когда-использовать}

-   State doesn't fit in memory
-   Need fast restart without bootstrap from Kafka
-   High throughput (embedded store is faster than network DBs)
-   Willing to manage store lifecycle manually (compaction, backup)


## Approach 4: Repartitioning via intermediate topic {#подход-4-repartitioning-промежуточный-топик}


### How it works {#как-работает}

If two topics are partitioned differently (different keys or different partition counts), direct partition-local join is impossible. Solution: **produce** events from one (or both) topics to an intermediate topic partitioned by the join key.

```text
Topic A (by user_id, 12 partitions)  ──► re-key by order_id ──► Intermediate A' (by order_id, 8 partitions)
Topic B (by order_id, 8 partitions)  ──────────────────────────► (already correct)

Intermediate A' + Topic B → partition-local join (approach 1 or 3)
```

This is the analog of `KStream#repartition()` from Kafka Streams, but done manually ([Kafka Streams Co-Partitioning Requirements Illustrated](https://medium.com/publicis-sapient-france/kafka-streams-co-partitioning-requirements-illustrated-2033f686b19c)).


### Implementation {#реализация}

1.  Consumer reads Topic A
2.  For each event, extracts the join key from the value
3.  Producer sends the event to the intermediate topic with `key=join_key` (Kafka's default partitioner ensures hash-based routing)
4.  The intermediate topic has the same number of partitions as Topic B
5.  A second consumer reads the intermediate topic + Topic B and performs partition-local join


### Semantics {#семантики}

Repartitioning adds **one more hop** through Kafka. For exactly-once, Kafka transactions are needed at the re-key stage:

```text
producer.beginTransaction()
producer.send(rekeyed_record_to_intermediate)
producer.sendOffsetsToTransaction(source_offsets, consumerGroupId)
producer.commitTransaction()
```


### Gotchas {#gotchas}

-   **Double latency** — the event passes through two topics (original + intermediate) before the join
-   **Additional storage** — the intermediate topic stores a copy of the data
-   **Ordering** — when re-keying, message order changes (different keys → different partitions → different order)
-   **Exactly-once overhead** — transactions add latency and reduce throughput (~20--30%)


### When to use {#когда-использовать}

-   Topics have different partitioning keys and can't be changed (producers are owned by others)
-   Topics have different partition counts and can't be recreated
-   Need partition-local join for horizontal scaling


## Approach 5: Database-backed join {#подход-5-database-backed-join}


### How it works {#как-работает}

Both consumers write events to a shared DB (PostgreSQL, Redis, etc.). The join is performed via SQL query or get-by-key.

```text
Topic A ──► Consumer A ──► INSERT INTO events_a (key, payload, ts)
Topic B ──► Consumer B ──► INSERT INTO events_b (key, payload, ts)

SELECT a.*, b.*
FROM events_a a JOIN events_b b ON a.key = b.key
WHERE ...
```

Technically this is an "external dependency", but in practice — the most common approach for services that already have PostgreSQL or Redis.


### Database options {#варианты-бд}


#### PostgreSQL {#postgresql}

-   SQL join — any complexity (inner, left, window functions)
-   UPSERT (`ON CONFLICT DO UPDATE`) — idempotent writes
-   Indexes on join key — fast lookups
-   LISTEN/NOTIFY or polling — for join readiness notification
-   **Downside**: write + read latency; at high throughput can become a bottleneck


#### Redis {#redis}

-   `HSET` / `HGET` — fast key-value lookup
-   `MULTI/EXEC` — atomic write of both sides
-   TTL — automatic expiry of unpaired events (windowed join analog)
-   Pub/Sub — join readiness notification
-   **Downside**: limited by RAM size; no SQL for complex joins


### Semantics {#семантики}

**At-least-once**: consumer writes to DB, then commits offset. On restart — repeated writes; the DB must handle them idempotently (`UPSERT`, `SET`).

**Exactly-once**: difficult because Kafka offset commit and DB write are **two different systems** (no distributed transaction). Options:

-   **Outbox pattern**: write to DB + offset in the same DB transaction. Consumer reads offset from DB at startup, not from Kafka.
-   **Idempotent writes**: accept at-least-once but make writes idempotent (by message ID/offset).


### Recovery on restart {#восстановление-при-рестарте}

State is in the DB — **survives restart**. The consumer simply continues from the last committed offset.

On DB loss — standard recovery from backup. Data in Kafka (retention) allows re-reading and restoring.


### Gotchas {#gotchas}

-   **Network latency** — each event requires a round-trip to the DB. Batching helps (`INSERT ... VALUES (...), (...), ...`), but adds latency.
-   **DB pressure** — at high throughput, the DB may not keep up. Need to monitor connections, lock contention, WAL size.
-   **Consistency** — between DB write and offset commit, there's a window where a crash can lead to inconsistency. Outbox pattern solves this but adds complexity.
-   **Scaling** — the DB becomes a single point of failure and bottleneck. Unlike partition-local approaches, it doesn't scale horizontally (without sharding).


### When to use {#когда-использовать}

-   The service already has PostgreSQL/Redis
-   The join is complex (multi-way, conditional, aggregation) — easier to write SQL
-   Throughput is moderate (thousands, not millions of events/sec)
-   Need long-term history of joined data (not just streaming)
-   Willing to handle DB operational load


## Approaches comparison table {#сводная-таблица-подходов}

| Approach             | Memory/Disk | Restart             | Co-partition needed? | Complexity | Best for                       |
|----------------------|-------------|---------------------|----------------------|-----------|--------------------------------|
| **In-memory**        | RAM         | State loss          | Yes                  | Low       | Simple joins, small state      |
| **Compacted lookup** | RAM         | Bootstrap           | No                   | Low       | Reference enrichment           |
| **Embedded store**   | Disk        | Instant             | Yes                  | Medium    | Large state, fast restart      |
| **Repartitioning**   | Kafka       | N/A (stateless hop) | Creates co-partition | Medium    | Different partitioning         |
| **Database-backed**  | External DB | Instant             | No                   | High      | Complex joins, existing DB     |


## Common edge cases and recommendations {#общие-edge-cases-и-рекомендации}


### Late arrivals and out-of-order {#late-arrivals-и-out-of-order}

Kafka guarantees order only **within a single partition** ([Aiven: Does Kafka Preserve Message Ordering?](https://aiven.io/blog/kafka-real-ordering)). Between two topics (and even between partitions of one topic) order is not guaranteed.

What to do:

-   **Buffer with grace period** — keep the window open longer than the expected lag
-   **Watermark** — track the minimum timestamp across all consumed partitions; consider all events older than the watermark as "late"
-   **Dead letter topic** — send late events to a separate topic for manual or deferred processing


### Rebalancing and state {#rebalancing-и-state}

During rebalance, the consumer loses some partitions and gains new ones. For partition-local state (approaches 1, 3):

-   On `onPartitionsRevoked` — save state (flush to store, commit offsets)
-   On `onPartitionsAssigned` — restore state for new partitions

Recommendations:

-   `CooperativeStickyAssignor` — minimizes partition movement
-   `group.instance.id` (static membership) — prevents rebalance during short restarts
-   `partition.assignment.strategy=cooperative-sticky` ([Cooperative Rebalancing](https://www.confluent.io/blog/cooperative-rebalancing-in-kafka-streams-consumer-ksqldb/))


### Exactly-once: the common pattern {#exactly-once-общий-паттерн}

For read-process-write in Kafka (approaches 1, 3, 4) — Kafka transactions:

1.  `producer.initTransactions()` at startup
2.  `producer.beginTransaction()` before processing a batch
3.  `producer.send(output_records)` — write results
4.  `producer.sendOffsetsToTransaction(offsets, groupId)` — commit offsets
5.  `producer.commitTransaction()` — atomic commit

Consumer on the output topic must read with `isolation.level=read_committed` ([Baeldung: Exactly Once Processing in Kafka with Java](https://www.baeldung.com/kafka-exactly-once)).

For approach 5 (database-backed) — outbox pattern or idempotent writes.


## Memory optimization: windowed buffer and probabilistic structures {#оптимизация-памяти-windowed-буфер-и-вероятностные-структуры}

Scenario: consumer reads Topic A, extracts the join key from the body, and waits for this key to appear in Topic B. The wait window is bounded (e.g., 4 hours). How to minimize memory consumption?


### Windowed buffer instead of full storage {#windowed-буфер-вместо-полного-хранения}

Instead of an infinite buffer — store pending events only within the time window. Three approaches to eviction:


#### Naive per-key TTL {#наивный-per-key-ttl}

`HashMap<Key, (Event, Expiry)>` + a background thread for periodic scanning. Problems: O(N) scan per tick, lock contention.


#### Timing Wheel {#timing-wheel--колесо-таймеров}

A classic structure from [Varghese & Lauck 1987](https://blog.acolyer.org/2015/11/23/hashed-and-hierarchical-timing-wheels/). Insert, cancel, expire — O(1) amortized.

```text
Slots: |0|1|2|3|4|5|6|7|  (tick = 1 minute, 8 slots = 8 minutes)
        ^
    current tick

Each slot — a linked list of timers, on advance — everything in the current slot is expired.
```

For a 4-hour window with minute granularity: 240 slots. **Hierarchical timing wheel** — multiple levels with different granularity. Apache Kafka uses [hierarchical timing wheels](https://www.confluent.io/blog/apache-kafka-purgatory-hierarchical-timing-wheels/) for Kafka Purgatory.


#### Time-bucketed HashMap {#time-bucketed-hashmap}

Instead of a single HashMap — split the buffer into time buckets. Each bucket is a separate HashMap for a 15-minute interval. When a bucket expires — drop it entirely in O(1).

```text
4-hour window, 15-minute buckets = 16 buckets

Bucket 0: [12:00-12:15) → HashMap{key1: event, key2: event, ...}
Bucket 1: [12:15-12:30) → HashMap{key3: event, ...}
...
Bucket 15: [15:45-16:00) → HashMap{...}

Current time: 16:05 → Bucket 0 expired → drop entire HashMap
```

Lookup by key — check all 16 active buckets: O(16), each HashMap.get — O(1). Trade-off: TTL granularity is coarsened to the bucket size.


### Bloom filters and Cuckoo filters: skipping 99% of Topic B events {#bloom-фильтры-и-cuckoo-фильтры-пропуск-99-событий-topic-b}

The core idea: most events in Topic B **have no pair** in the pending buffer. Instead of a HashMap/RocksDB lookup for every event — use a probabilistic check.

| Property              | Bloom filter | Counting Bloom | Cuckoo filter |
|-----------------------|--------------|----------------|---------------|
| Deletion              | No           | Yes            | Yes           |
| Bits/element (FPR ~1%)| ~10          | ~30--40        | ~12           |
| Worst-case lookup     | O(k)         | O(k)           | O(1)          |

**Cuckoo filter** ([Fan et al. 2014](https://www.cs.cmu.edu/~dga/papers/cuckoo-conext2014.pdf)) — the optimal choice for stream join: native deletion support (after a successful join, the key is removed from the filter) with memory comparable to Bloom filter.

Numeric example: 1M pending keys at FPR ~1%:

-   Cuckoo filter: 1M × 12 bits = **1.5 MB**
-   `HashMap<String, _>` keys only: **50--100 MB**


### Two-level architecture: Cuckoo (L1) + RocksDB (L2) {#двухуровневая-архитектура-cuckoo--l1--plus-rocksdb--l2}

```text
Topic B event ──► Cuckoo filter (L1, in-memory)
                    │
                    ├── "no" ──► skip (99% of events)
                    │
                    └── "maybe yes" ──► RocksDB lookup (L2, on-disk)
                                            │
                                            ├── found ──► emit joined, delete from L1 and L2
                                            └── not found ──► false positive, skip
```

With 1M pending keys, Topic B at 100K events/sec, match rate ~1%:

-   Without filter: 100K lookups/sec in RocksDB
-   With cuckoo filter (FPR 1%): 1K real + 1K false positive = 2K lookups/sec — **50x reduction in L2 load**

RocksDB itself uses [Bloom filters](https://github.com/facebook/rocksdb/wiki/RocksDB-Bloom-Filter) on SST files — this is a **third level** of filtering: our cuckoo (L1) → RocksDB (L2) → bloom in SST (L2.5) → disk read.


### What to store in the buffer: full event vs. key+offset vs. projection {#что-хранить-в-буфере-full-event-vs-dot-key-plus-offset-vs-dot-проекция}

| Variant                          | Size per 1M events (payload ~1 KB) | Trade-off                                                                     |
|----------------------------------|-------------------------------------|-------------------------------------------------------------------------------|
| **Full event**                   | ~1.1 GB                             | Instant emit, but expensive in RAM                                            |
| **Key + offset**                 | ~88 MB (12× less)                   | Needs re-fetch from Kafka on match (+1--10 ms), doesn't work with compacted topics |
| **Key + projection (needed fields)** | ~136 MB                         | Best compromise if output fields are known in advance                         |

Recommendations:

-   Pending events < 100K, payload < 1 KB → full event (simplicity)
-   Pending events 100K--10M → projection or key+offset
-   Payload > 10 KB → key+offset (savings are critical)


### Compact key representation {#компактное-представление-ключей}

Hashing string keys to a fixed size:

| Hash size | Collisions at 1M keys |
|-----------|-----------------------|
| 64 bits   | ~1 in 4×10^12         |
| 128 bits  | ~1.5×10^(-26)         |

128-bit hash (SipHash, xxHash128) — a safe choice. Savings: string ~36 bytes → hash 16 bytes.


### Combined production architecture {#комбинированная-архитектура-для-production}

Putting it all together: 4-hour window, 1--5M pending keys, payload ~1 KB.

```text
Topic A ──► extract join key ──► hash to u64 ──► insert into:
                                                  ├── Cuckoo filter (L1, ~7.5 MB)
                                                  └── Time-bucketed RocksDB (L2, on-disk)
                                                       key: u64 hash
                                                       value: projected payload (~60 bytes)
                                                       16 buckets of 15 min

Topic B ──► extract key ──► hash to u64 ──► check Cuckoo filter (L1)
                                              │
                                              ├── miss → skip (99% of events)
                                              └── hit → RocksDB lookup (L2)
                                                    │
                                                    ├── found → emit joined, delete from L1+L2
                                                    └── not found → false positive, skip

Eviction: every 15 minutes → drop oldest time bucket from RocksDB
                            → rebuild Cuckoo filter (or per-bucket filters)
```


#### Resource estimate for 5M pending keys {#оценка-ресурсов-для-5m-pending-ключей}

| Component           | Size            |
|---------------------|-----------------|
| Cuckoo filter       | ~7.5 MB         |
| RocksDB (on-disk)   | ~400 MB         |
| RocksDB block cache | 64--128 MB RAM  |
| **Total RAM**       | **~70--136 MB** |
| **Total Disk**      | **~400 MB**     |

For comparison: a naive `HashMap<String, FullEvent>` with 5M entries = **~5.5 GB RAM**.


## What Kafka Streams does under the hood {#что-делает-kafka-streams-под-капотом}

For context: Kafka Streams implements joins using exactly the same primitives:

-   **KStream-KStream join** — two in-memory/RocksDB stores (one per side), windowed, with changelog topics for recovery. This is [approach 1](#подход-1-client-side-join-с-in-memory-store) + [approach 3](#подход-3-embedded-state-store--rocksdb-badgerdb-sqlite)
-   **KStream-KTable join** — one store for the table side, stream side does lookups. This is [approach 2](#подход-2-compacted-topic-как-lookup-table) with RocksDB instead of HashMap
-   **KStream-GlobalKTable join** — the table is replicated to all instances (all partitions), doesn't require co-partitioning. This is [approach 2](#подход-2-compacted-topic-как-lookup-table) in its pure form
-   **Repartitioning** — automatic creation of intermediate topics on key mismatch. This is [approach 4](#подход-4-repartitioning-промежуточный-топик)

Kafka Streams adds: automatic changelog, rebalance-aware state management, standby replicas, exactly-once via Kafka transactions, metrics, fault tolerance. If you need all of this — it's easier to use Kafka Streams than to implement it manually. Manual implementation is justified when:

-   No JVM (Go, Rust, Python)
-   Need minimal footprint (single binary without a framework)
-   The join is trivial and doesn't justify the Kafka Streams dependency
-   Need custom logic that's hard to express via Kafka Streams DSL


## Rust implementation: rdkafka and the crate ecosystem {#реализация-на-rust-rdkafka-и-экосистема-крейтов}

Rust is one of the main use cases for manual join implementation: no Kafka Streams (JVM-only), no mature stream-processing frameworks. The [rust-rdkafka](https://github.com/fede1024/rust-rdkafka) crate (v0.39, librdkafka under the hood) provides a full consumer/producer API with tokio integration.


### rdkafka: consuming from multiple topics {#rdkafka-потребление-из-нескольких-топиков}

`StreamConsumer` supports subscribing to multiple topics in a single `subscribe` call:

```rust
use rdkafka::consumer::{Consumer, StreamConsumer};
use rdkafka::ClientConfig;

let consumer: StreamConsumer = ClientConfig::new()
    .set("group.id", "join-worker")
    .set("bootstrap.servers", "kafka:9092")
    .set("enable.auto.commit", "true")
    .set("auto.commit.interval.ms", "5000")
    .set("enable.auto.offset.store", "false")  // manual store_offset
    .set("auto.offset.reset", "earliest")
    .create()
    .expect("consumer creation failed");

// One consumer, two topics
consumer.subscribe(&["orders", "payments"])
    .expect("subscribe failed");
```

The `recv().await` method returns a `BorrowedMessage` with a `.topic()` method — used to determine the source:

```rust
loop {
    match consumer.recv().await {
        Ok(msg) => {
            match msg.topic() {
                "orders" => handle_order(&msg, &state).await,
                "payments" => handle_payment(&msg, &state).await,
                _ => {}
            }
            // store offset only after successful processing
            consumer.store_offset_from_message(&msg).unwrap();
        }
        Err(e) => warn!("kafka error: {e}"),
    }
}
```


#### One consumer vs. two {#один-consumer-vs-dot-два}

| Variant                                   | Pros                                                        | Cons                                               |
|-------------------------------------------|-------------------------------------------------------------|----------------------------------------------------|
| **One consumer, two topics**              | Single event loop, no synchronization, simpler offset mgmt  | Slow topic blocks the fast one (head-of-line)      |
| **Two consumers, one per topic**          | Independent throughput, can have different `group.id`        | State synchronization needed (`Arc<Mutex>` or channel) |
| **One consumer + split_partition_queue**  | Partition-level separation without separate consumers       | Harder to manage, state is still shared            |

For join, the recommendation: **one consumer for both topics**. This guarantees that on rebalance, partitions of both topics are assigned consistently (one `group.id`, one assignment). With two consumers using different groups, there's no guarantee that one instance gets "matching" partitions.


#### StreamConsumer vs. BaseConsumer {#streamconsumer-vs-dot-baseconsumer}

`StreamConsumer` — async, integrated with tokio (default runtime). The `recv()` method is cancellation-safe, usable in `tokio::select!`.

`BaseConsumer` — sync, requires manual `poll()`. Suitable for cases without an async runtime or when full control over the polling loop is needed.

For joins, `StreamConsumer` is preferable: async allows combining consumption with HTTP/gRPC, eviction timers, and metrics.

**Critical constraint**: when using `subscribe()` (consumer group protocol), `recv()` must be called at least once every `max.poll.interval.ms` (default 300s), otherwise librdkafka considers the consumer stuck and triggers a rebalance.


### Full sketch: windowed join with TTL buffer {#полный-скетч-windowed-join-с-ttl-буфером}

```rust
use std::sync::Arc;

use moka::future::Cache;
use rdkafka::consumer::{Consumer, StreamConsumer};
use rdkafka::message::BorrowedMessage;
use rdkafka::producer::{FutureProducer, FutureRecord};
use rdkafka::{ClientConfig, Message};
use serde::Deserialize;
use std::time::Duration;

#[derive(Debug, Deserialize, Clone)]
struct Order {
    order_id: String,
    payment_ref: String,
    items: Vec<String>,
}

#[derive(Debug, Deserialize, Clone)]
struct Payment {
    payment_id: String,
    amount: u64,
    status: String,
}

/// Join sides: one side has arrived, waiting for the other
#[derive(Debug, Clone)]
enum Pending {
    HasOrder(Order),
    HasPayment(Payment),
}

/// moka::future::Cache with TTL = join window.
/// Key — join key (payment_ref / payment_id).
/// On TTL eviction — event didn't find a pair (can send to DLT).
type JoinBuffer = Cache<String, Pending>;

fn create_consumer(brokers: &str, group: &str) -> StreamConsumer {
    ClientConfig::new()
        .set("group.id", group)
        .set("bootstrap.servers", brokers)
        .set("enable.auto.commit", "true")
        .set("auto.commit.interval.ms", "5000")
        .set("enable.auto.offset.store", "false")
        .set("auto.offset.reset", "earliest")
        .set("session.timeout.ms", "10000")
        .create()
        .expect("consumer creation failed")
}

fn create_producer(brokers: &str) -> FutureProducer {
    ClientConfig::new()
        .set("bootstrap.servers", brokers)
        .set("message.timeout.ms", "5000")
        .create()
        .expect("producer creation failed")
}

#[tokio::main]
async fn main() {
    let consumer = create_consumer("kafka:9092", "join-worker");
    consumer.subscribe(&["orders", "payments"]).unwrap();

    let producer = create_producer("kafka:9092");

    // TTL = 5 minutes — join window
    let buffer: JoinBuffer = Cache::builder()
        .time_to_live(Duration::from_secs(300))
        .max_capacity(1_000_000)
        .async_eviction_listener(|key, value, _cause| {
            Box::pin(async move {
                // No pair found — log or send to DLT
                tracing::warn!(key = %key, "join timeout: unmatched event");
            })
        })
        .build();

    loop {
        match consumer.recv().await {
            Ok(msg) => {
                let payload = match msg.payload() {
                    Some(p) => p,
                    None => continue,
                };
                match msg.topic() {
                    "orders" => {
                        if let Ok(order) = serde_json::from_slice::<Order>(payload) {
                            try_join_order(&buffer, &producer, order).await;
                        }
                    }
                    "payments" => {
                        if let Ok(payment) = serde_json::from_slice::<Payment>(payload) {
                            try_join_payment(&buffer, &producer, payment).await;
                        }
                    }
                    _ => {}
                }
                consumer.store_offset_from_message(&msg).unwrap();
            }
            Err(e) => tracing::warn!("kafka error: {e}"),
        }
    }
}

async fn try_join_order(buf: &JoinBuffer, producer: &FutureProducer, order: Order) {
    let key = order.payment_ref.clone();
    match buf.remove(&key).await {
        Some(Pending::HasPayment(payment)) => {
            emit_joined(producer, &order, &payment).await;
        }
        _ => {
            buf.insert(key, Pending::HasOrder(order)).await;
        }
    }
}

async fn try_join_payment(buf: &JoinBuffer, producer: &FutureProducer, payment: Payment) {
    let key = payment.payment_id.clone();
    match buf.remove(&key).await {
        Some(Pending::HasOrder(order)) => {
            emit_joined(producer, &order, &payment).await;
        }
        _ => {
            buf.insert(key, Pending::HasPayment(payment)).await;
        }
    }
}

async fn emit_joined(producer: &FutureProducer, order: &Order, payment: &Payment) {
    let joined = serde_json::json!({
        "order_id": order.order_id,
        "payment_id": payment.payment_id,
        "amount": payment.amount,
        "status": payment.status,
        "items": order.items,
    });
    let payload = joined.to_string();
    let record = FutureRecord::to("joined-events")
        .key(&order.order_id)
        .payload(&payload);
    if let Err((e, _)) = producer.send(record, Duration::from_secs(5)).await {
        tracing::error!("failed to send joined event: {e}");
    }
}
```


### Manual offset commit: the at-least-once pattern {#ручной-commit-offset-паттерн-at-least-once}

The key trick: `enable.auto.commit=true` + `enable.auto.offset.store=false`. Auto-commit works on a timer but only commits **explicitly stored** offsets. Calling `store_offset_from_message(&msg)` marks the offset as ready to commit.

```rust
// DON'T do: commit on every message (slow, broker load)
// consumer.commit_message(&msg, CommitMode::Async).unwrap();

// DO: store offset, auto-commit will send the batch
consumer.store_offset_from_message(&msg).unwrap();
```

On crash between `store_offset` and auto-commit — the message will be re-read (at-least-once). Processing must be idempotent.

For **manual commit** without auto-commit:

```rust
// enable.auto.commit = false
// Commit manually every N messages or by timer
consumer.commit_message(&msg, CommitMode::Async).unwrap();
// or
consumer.commit_consumer_state(CommitMode::Async).unwrap();
```


### Rebalance callbacks in rdkafka {#rebalance-callbacks-в-rdkafka}

The `ConsumerContext` trait allows intercepting rebalances. This is critical for joins: when losing a partition, state for it needs to be cleared.

```rust
use rdkafka::consumer::{ConsumerContext, Rebalance};
use rdkafka::client::ClientContext;

struct JoinContext {
    // reference to state for cleanup on rebalance
}

impl ClientContext for JoinContext {}

impl ConsumerContext for JoinContext {
    fn pre_rebalance(&self, rebalance: &Rebalance) {
        match rebalance {
            Rebalance::Revoke(tpl) => {
                // Partitions being revoked — flush pending state,
                // commit offsets for these partitions
                tracing::info!("partitions revoked: {:?}", tpl);
            }
            Rebalance::Assign(tpl) => {
                tracing::info!("partitions assigned: {:?}", tpl);
            }
            Rebalance::Error(err) => {
                tracing::error!("rebalance error: {}", err);
            }
        }
    }

    fn post_rebalance(&self, rebalance: &Rebalance) {
        if let Rebalance::Assign(_tpl) = rebalance {
            // New partitions — can start bootstrapping state
        }
    }

    fn commit_callback(
        &self,
        result: rdkafka::error::KafkaResult<()>,
        offsets: &rdkafka::TopicPartitionList,
    ) {
        if let Err(e) = result {
            tracing::error!("commit failed: {e}, offsets: {:?}", offsets);
        }
    }
}

// Usage:
let context = JoinContext { /* ... */ };
let consumer: StreamConsumer<JoinContext> = ClientConfig::new()
    // ... config ...
    .create_with_context(context)
    .expect("consumer creation failed");
```

**Important**: `pre_rebalance` and `post_rebalance` are called from librdkafka's polling thread and must complete quickly. No async I/O inside — only update flags/counters.


### RocksDB variant for state store {#вариант-с-rocksdb-для-state-store}

If the buffer doesn't fit in RAM or fast restart is needed — `moka` is replaced with `rocksdb`:

```rust
use rocksdb::{DB, Options};

fn open_state_store(path: &str) -> DB {
    let mut opts = Options::default();
    opts.create_if_missing(true);
    opts.set_max_write_buffer_number(4);
    // TTL via compaction filter — rocksdb will delete expired entries
    DB::open(&opts, path).unwrap()
}

/// Write to store: key = join_key, value = serialized Pending + timestamp
fn put_pending(db: &DB, join_key: &str, pending: &Pending) {
    let value = serde_json::to_vec(pending).unwrap();
    db.put(join_key.as_bytes(), &value).unwrap();
}

/// Lookup + delete (atomic get-and-remove via delete after get)
fn take_pending(db: &DB, join_key: &str) -> Option<Pending> {
    match db.get(join_key.as_bytes()) {
        Ok(Some(bytes)) => {
            db.delete(join_key.as_bytes()).unwrap();
            serde_json::from_slice(&bytes).ok()
        }
        _ => None,
    }
}
```

For TTL in RocksDB: use `compaction_filter` that checks the timestamp in the value and deletes entries older than the window. Or store the offset in RocksDB itself and on restart — `consumer.seek()` to the saved offset.


### Crate ecosystem {#экосистема-крейтов}

| Crate                                                                                       | Version | Purpose                                    |
|---------------------------------------------------------------------------------------------|--------|--------------------------------------------|
| [rdkafka](https://crates.io/crates/rdkafka)                                                 | 0.39   | Kafka consumer/producer, tokio integration |
| [serde](https://crates.io/crates/serde) + [serde_json](https://crates.io/crates/serde_json) | 1.x    | JSON payload deserialization               |
| [moka](https://crates.io/crates/moka)                                                       | 0.12   | Async TTL cache (`HashMap` + timer replacement) |
| [dashmap](https://crates.io/crates/dashmap)                                                 | 6.x    | Concurrent `HashMap` (no TTL, but faster)  |
| [rocksdb](https://crates.io/crates/rocksdb)                                                 | 0.24   | Embedded KV store (Kafka Streams analog)   |
| [tracing](https://crates.io/crates/tracing)                                                 | 0.1    | Structured logging                         |
| [tokio](https://crates.io/crates/tokio)                                                     | 1.x    | Async runtime (`StreamConsumer` default)   |


#### moka vs. dashmap for the join buffer {#moka-vs-dot-dashmap-для-join-буфера}

`moka::future::Cache` — the **preferred choice** for windowed join:

-   Built-in TTL (`time_to_live`) — automatic eviction by timeout, no need to write your own reaper
-   `async_eviction_listener` — callback on eviction, can send to dead letter topic
-   Admission policy (TinyLFU) — on overflow, evicts the least useful entries, not random ones
-   Thread-safe, works with `tokio`

`dashmap` — if TTL isn't needed (infinite buffer / lookup table) or you need a raw concurrent `HashMap` with maximum speed. No built-in eviction — must implement yourself (background tokio task with `retain`).


#### mini-moka vs. moka {#mini-moka-vs-dot-moka}

[mini-moka](https://github.com/moka-rs/mini-moka) — a simplified version without async cache, without per-entry expiration, without lock-free iterator. Suitable for sync contexts where `future::Cache` isn't needed. For joins with tokio — use full `moka`.


### Known limitations and pitfalls {#известные-ограничения-и-грабли}

1.  **librdkafka thread model** — rdkafka uses librdkafka's internal threads for networking and polling. `StreamConsumer::recv()` is cancellation-safe, but `stream()` is not. Use `recv()` in `tokio::select!`.

2.  **max.poll.interval.ms** — if message processing (deserialization + lookup + produce) takes longer than 300s, the consumer will be kicked from the group. For heavy processing — increase the timeout or offload work to `tokio::spawn`.

3.  **Message ordering** — when consuming two topics with one consumer, order between topics is **not guaranteed**. A "payments" message can arrive before the corresponding "orders" message. A buffer is mandatory.

4.  **Rebalance and state** — on rebalance, `moka` cache **doesn't know** about partitions. If one instance was receiving partition 0 of "orders" and put a pending event in cache, and after rebalance the partition moved to another instance — the pending event stays in the first instance's cache and will never be matched. For partition-local join, maintain separate state per partition (`HashMap<(topic, partition), Cache>`) and clear on `Rebalance::Revoke`.

5.  **Backpressure** — `FutureProducer::send` blocks if librdkafka's internal buffer is full (`queue.buffering.max.messages`, default 100000). At high join throughput, the producer can become a bottleneck.


## Overview of existing solutions {#обзор-существующих-решений}

A brief overview of libraries and frameworks for stream joins on top of Kafka — focusing on Go and Rust.


### Go {#go}


#### [Goka](https://github.com/lovoo/goka) — stream-table join (2.5k stars, actively maintained) {#goka-stream-table-join--2-dot-5k-stars-активно-поддерживается}

The most mature Go library for stateful stream processing. Provides `ctx.Join(table)` (co-partitioned stream-table join by current key) and `ctx.Lookup(table, key)` (lookup join for arbitrary key without co-partitioning). State is stored in LevelDB (pluggable). Views — read-only cache of the entire table (GlobalKTable analog).

Limitations:

-   **No KStream-KStream windowed join** — only stream-table
-   **No exactly-once** — at-least-once only
-   Suitable for enrichment, but not for bidirectional stream-stream join


#### [franz-go](https://github.com/twmb/franz-go) — best Kafka client for Go (2.7k stars) {#franz-go-лучший-kafka-клиент-для-go--2-dot-7k-stars}

The most full-featured pure-Go Kafka client. Supports transactions (the only Go client with EOS), cooperative rebalancing, admin API. **No** join abstractions — it's the foundation on which manual logic is built. In practice, most Go teams do exactly this: franz-go + Redis/RocksDB + manual join.


#### [gmbyapa/kstream](https://github.com/gmbyapa/kstream) — Kafka Streams port for Go (30 stars) {#gmbyapa-kstream-порт-kafka-streams-на-go--30-stars}

Closest to Java Kafka Streams by API: KTable-KTable join, KStream-KTable join, KStream-GlobalKTable join, Foreign-Key join. Pluggable state store, EOS claimed. **But**: 30 stars, low activity — risky for production.


#### [Redpanda Connect / Benthos](https://github.com/redpanda-data/connect) — ETL processor (8.6k stars) {#redpanda-connect-benthos-etl-процессор--8-dot-6k-stars}

300+ connectors, YAML configuration. Join is implemented via an [enrichment pattern](https://docs.redpanda.com/redpanda-connect/cookbooks/joining_streams/): one pipeline writes to a Redis cache, the other does lookups. Not stateful stream processing — more like a programmable Kafka Connect.


#### Go summary {#итого-по-go}

A full analog of Java Kafka Streams with KStream-KStream windowed join and EOS in Go **does not exist**. The real-world pattern: franz-go (or sarama) + manual state in Redis/RocksDB. For stream-table join — Goka.


### Rust {#rust}


#### [rust-rdkafka](https://github.com/fede1024/rust-rdkafka) — standard Kafka client (1.9k stars) {#rust-rdkafka-стандартный-kafka-клиент--1-dot-9k-stars}

A wrapper over librdkafka with async/tokio integration. Supports transactions. No stream processing abstractions — the foundation for manual implementation (details in the [section above](#реализация-на-rust-rdkafka-и-экосистема-крейтов)).


#### [Arroyo](https://github.com/ArroyoSystems/arroyo) — stream processing engine (4.8k stars, Cloudflare) {#arroyo-stream-processing-engine--4-dot-8k-stars-cloudflare}

A full stream processing engine in Rust, comparable to Apache Flink. SQL-first interface. Supports inner/left/outer/full joins, windowed joins (tumbling, sliding, session), lookup joins. Kafka-native, EOS via transactions. Claims 5× Flink performance.

Key point: Arroyo is a **standalone engine** (deployed as a cluster), not an embeddable library. If you need full stream-stream windowed join with SQL — the best option in the Rust ecosystem.


#### [Fluvio](https://github.com/infinyon/fluvio) — Rust-native streaming platform (5.2k stars) {#fluvio-rust-native-стриминговая-платформа--5-dot-2k-stars}

A **Kafka replacement**, not a Kafka client. Its own broker + Stateful DataFlow (SDF) with SQL joins, GROUP BY, aggregation via WASM SmartModules. If you're committed to Kafka — Fluvio doesn't fit directly (though there are connectors).


#### [Callysto](https://github.com/vertexclique/callysto) — Kafka Streams port for Rust (160 stars, stale) {#callysto-порт-kafka-streams-на-rust--160-stars-stale}

An attempt to create a Kafka Streams-like framework for Rust. Last release — October 2022. Effectively abandoned. Not recommended.


### Comparison table {#сводная-таблица}

| Library              | Language | Stars | Joins          | State store  | EOS | Status               |
|----------------------|------|-------|----------------|--------------|-----|----------------------|
| **Goka**             | Go   | 2.5k  | Stream-table   | LevelDB      | No  | Active               |
| **franz-go**         | Go   | 2.7k  | None (client)  | —            | Yes | Active               |
| **gmbyapa/kstream**  | Go   | 30    | KTable/KStream | Pluggable KV | Yes | Low activity         |
| **Redpanda Connect** | Go   | 8.6k  | Enrichment     | External     | No  | Active               |
| **Arroyo**           | Rust | 4.8k  | Full SQL joins | Built-in     | Yes | Active (Cloudflare)  |
| **Fluvio**           | Rust | 5.2k  | SQL (SDF)      | Built-in     | Yes | Active               |
| **rdkafka**          | Rust | 1.9k  | None (client)  | —            | Yes | Active               |
| **Callysto**         | Rust | 160   | Unclear        | —            | —   | Abandoned            |


### Conclusion {#вывод}

For **Go with Kafka joins**: no mature solution exists. Goka covers stream-table; for stream-stream — manual implementation on franz-go + state store.

For **Rust with Kafka joins**: Arroyo — if ready for a standalone engine. For an embeddable library — rdkafka + manual logic (moka/RocksDB for state, cuckoo filter for optimization, as described in the [optimization section](#оптимизация-памяти-windowed-буфер-и-вероятностные-структуры)).
